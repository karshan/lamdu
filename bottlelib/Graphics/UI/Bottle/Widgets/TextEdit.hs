{-# LANGUAGE OverloadedStrings, TemplateHaskell #-}
module Graphics.UI.Bottle.Widgets.TextEdit(
  Cursor, Style(..), make, defaultCursorColor, defaultCursorWidth,
  makeTextEditCursor,
  atSCursorColor,
  atSCursorWidth,
  atSTextCursorId,
  atSBackgroundCursorId,
  atSEmptyUnfocusedString,
  atSEmptyFocusedString,
  atSTextViewStyle
  ) where

import Control.Arrow (first)
import Control.Lens ((%~), (^.))
import Data.Char (isSpace)
import Data.List (genericLength, minimumBy)
import Data.List.Split (splitWhen)
import Data.List.Utils (enumerate)
import Data.Maybe (mapMaybe)
import Data.Monoid (Monoid(..))
import Data.Ord (comparing)
import Data.Vector.Vector2 (Vector2(..))
import Graphics.DrawingCombinators.Utils (square, textHeight)
import Graphics.UI.Bottle.Rect (Rect(..))
import Graphics.UI.Bottle.Widget (Widget(..))
import qualified Control.Lens as Lens
import qualified Data.AtFieldTH as AtFieldTH
import qualified Data.Binary.Utils as BinUtils
import qualified Data.ByteString.Char8 as SBS8
import qualified Data.Map as Map
import qualified Data.Set as Set
import qualified Data.Vector.Vector2 as Vector2
import qualified Graphics.DrawingCombinators as Draw
import qualified Graphics.UI.Bottle.Animation as Anim
import qualified Graphics.UI.Bottle.Direction as Direction
import qualified Graphics.UI.Bottle.EventMap as E
import qualified Graphics.UI.Bottle.Rect as Rect
import qualified Graphics.UI.Bottle.Widget as Widget
import qualified Graphics.UI.Bottle.Widgets.TextView as TextView
import qualified Safe

type Cursor = Int

data Style = Style
  { sCursorColor :: Draw.Color
  , sCursorWidth :: Widget.R
  , sTextCursorId :: Anim.AnimId
  , sBackgroundCursorId :: Anim.AnimId
  , sBackgroundColor :: Draw.Color
  , sEmptyUnfocusedString :: String
  , sEmptyFocusedString :: String
  , sTextViewStyle :: TextView.Style
  }
AtFieldTH.make ''Style

defaultCursorColor :: Draw.Color
defaultCursorColor = Draw.Color 0 1 0 1

defaultCursorWidth :: Widget.R
defaultCursorWidth = 8

tillEndOfWord :: String -> String
tillEndOfWord xs = spaces ++ nonSpaces
  where
    spaces = takeWhile isSpace xs
    nonSpaces = takeWhile (not . isSpace) . dropWhile isSpace $ xs

makeDisplayStr :: String -> String -> String
makeDisplayStr empty ""  = empty
makeDisplayStr _     str = str

cursorTranslate :: Style -> Anim.Frame -> Anim.Frame
cursorTranslate style = Anim.translate (Vector2 (sCursorWidth style / 2) 0)

makeTextEditCursor :: Widget.Id -> Int -> Widget.Id
makeTextEditCursor myId = Widget.joinId myId . (:[]) . BinUtils.encodeS

rightSideOfRect :: Rect -> Rect
rightSideOfRect rect =
  Lens.set Rect.left (rect ^. Rect.right) .
  Lens.set Rect.width 0 $ rect

cursorRects :: Style -> String -> [Rect]
cursorRects style str =
  concat .
  -- A bit ugly: letterRects returns rects for all but newlines, and
  -- returns a list of lines. Then addFirstCursor adds the left-most
  -- cursor of each line, thereby the number of rects becomes the
  -- original number of letters which can be used to match the
  -- original string index-wise.
  zipWith addFirstCursor (iterate (+lineHeight) 0) .
  (map . map) rightSideOfRect $
  TextView.letterRects (sTextViewStyle style) str
  where
    addFirstCursor y = (Rect (Vector2 0 y) (Vector2 0 lineHeight) :)
    lineHeight = lineHeightOfStyle style

makeUnfocused :: Style -> String -> Widget.Id -> Widget ((,) String)
makeUnfocused style str myId =
  makeFocusable style str myId .
  (Widget.wSize . Vector2.first %~ (+ cursorWidth)) .
  Lens.over Widget.wFrame (cursorTranslate style) .
  TextView.makeWidget (sTextViewStyle style) displayStr $
  Widget.toAnimId myId
  where
    cursorWidth = sCursorWidth style
    displayStr = makeDisplayStr (sEmptyUnfocusedString style) str

makeFocusable ::
  Style -> String -> Widget.Id ->
  Widget ((,) String) -> Widget ((,) String)
makeFocusable style str myId =
  Lens.set Widget.wMaybeEnter $ Just mEnter
  where
    minimumOn = minimumBy . comparing
    rectToCursor fromRect =
      fst . minimumOn snd . enumerate . map (Rect.distance fromRect) $
      cursorRects style str
    mEnter dir =
      Widget.EnterResult cursorRect .
      (,) str . Widget.eventResultFromCursor $
      makeTextEditCursor myId cursor
      where
        cursor =
          case dir of
          Direction.Outside -> length str
          Direction.PrevFocalArea rect -> rectToCursor rect
          Direction.Point x -> rectToCursor $ Rect x 0
        cursorRect = mkCursorRect style cursor str

lineHeightOfStyle :: Style -> Widget.R
lineHeightOfStyle style = sz * textHeight
  where
    sz = fromIntegral . TextView.styleFontSize $ sTextViewStyle style

eventResult ::
  Widget.Id -> [(Maybe Int, Char)] -> [(Maybe Int, Char)] ->
  Int -> (String, Widget.EventResult)
eventResult myId strWithIds newText newCursor =
  (map snd newText,
    Widget.EventResult {
      Widget._eCursor = Just $ makeTextEditCursor myId newCursor,
      Widget._eAnimIdMapping = mapping
    })
  where
    myAnimId = Widget.toAnimId myId
    mapping animId = maybe animId (Anim.joinId myAnimId . translateId) $ Anim.subId myAnimId animId
    translateId [subId] = (:[]) . maybe subId (SBS8.pack . show) $ (`Map.lookup` dict) =<< Safe.readMay (SBS8.unpack subId)
    translateId x = x
    dict = mappend movedDict deletedDict
    movedDict = Map.fromList . mapMaybe posMapping . enumerate $ map fst newText
    deletedDict = Map.fromList . map (flip (,) (-1)) $ Set.toList deletedKeys
    posMapping (_, Nothing) = Nothing
    posMapping (newPos, Just oldPos) = Just (oldPos, newPos)
    deletedKeys =
      Set.fromList (mapMaybe fst strWithIds) `Set.difference`
      Set.fromList (mapMaybe fst newText)

-- TODO: Instead of font + ptSize, let's pass a text-drawer (that's
-- what "Font" should be)
-- | Note: maxLines prevents the *user* from exceeding it, not the
-- | given text...
makeFocused :: Cursor -> Style -> String -> Widget.Id -> Widget ((,) String)
makeFocused cursor style str myId =
  makeFocusable style str myId .
  Widget.backgroundColor 10 (sBackgroundCursorId style) (sBackgroundColor style) $
  widget
  where
    widget = Widget
      { _wIsFocused = True
      , _wSize = reqSize
      , _wFrame = img `mappend` cursorFrame
      , _wEventMap = eventMap cursor str displayStr myId
      , _wMaybeEnter = Nothing
      , _wFocalArea = cursorRect
      }
    reqSize = Vector2 (sCursorWidth style + tlWidth) tlHeight
    myAnimId = Widget.toAnimId myId
    img = cursorTranslate style $ frameGen myAnimId
    displayStr = makeDisplayStr (sEmptyFocusedString style) str
    (frameGen, Vector2 tlWidth tlHeight) = textViewDraw style displayStr

    cursorRect = mkCursorRect style cursor str
    cursorFrame =
      Anim.onDepth (+2) .
      Anim.unitIntoRect cursorRect .
      (Anim.simpleFrame . sTextCursorId) style $
      Draw.tint (sCursorColor style) square

textViewDraw ::
  Style -> String -> (Anim.AnimId -> Anim.Frame, Widget.Size)
textViewDraw = TextView.drawTextAsSingleLetters . sTextViewStyle

mkCursorRect :: Style -> Int -> String -> Rect
mkCursorRect style cursor str = Rect cursorPos cursorSize
  where
    beforeCursorLines = splitWhen (== '\n') $ take cursor str
    lineHeight = lineHeightOfStyle style
    cursorPos = Vector2 cursorPosX cursorPosY
    cursorSize = Vector2 (sCursorWidth style) lineHeight
    cursorPosX =
      Lens.view Vector2.first . snd . textViewDraw style $ last beforeCursorLines
    cursorPosY = (lineHeight *) . subtract 1 $ genericLength beforeCursorLines

eventMap ::
  Int -> String -> String -> Widget.Id ->
  Widget.EventHandlers ((,) String)
eventMap cursor str displayStr myId =
  mconcat . concat $ [
    [ keys "Move left" [specialKey E.KeyLeft] $
      moveRelative (-1)
    | cursor > 0 ],

    [ keys "Move right" [specialKey E.KeyRight] $
      moveRelative 1
    | cursor < textLength ],

    [ keys "Move word left" [ctrlSpecialKey E.KeyLeft]
      backMoveWord
    | cursor > 0 ],

    [ keys "Move word right" [ctrlSpecialKey E.KeyRight] moveWord
    | cursor < textLength ],

    [ keys "Move up" [specialKey E.KeyUp] $
      moveRelative (- cursorX - 1 - length (drop cursorX prevLine))
    | cursorY > 0 ],

    [ keys "Move down" [specialKey E.KeyDown] $
      moveRelative (length curLineAfter + 1 + min cursorX (length nextLine))
    | cursorY < lineCount - 1 ],

    [ keys "Move to beginning of line" homeKeys $
      moveRelative (-cursorX)
    | cursorX > 0 ],

    [ keys "Move to end of line" endKeys $
      moveRelative (length curLineAfter)
    | not . null $ curLineAfter ],

    [ keys "Move to beginning of text" homeKeys $
      moveAbsolute 0
    | cursorX == 0 && cursor > 0 ],

    [ keys "Move to end of text" endKeys $
      moveAbsolute textLength
    | null curLineAfter && cursor < textLength ],

    [ keys "Delete backwards" [specialKey E.KeyBackspace] $
      backDelete 1
    | cursor > 0 ],

    [ keys "Delete word backwards" [ctrlCharKey 'w']
      backDeleteWord
    | cursor > 0 ],

    let swapPoint = min (textLength - 2) (cursor - 1)
        (beforeSwap, x:y:afterSwap) = splitAt swapPoint strWithIds
        swapLetters = eventRes (beforeSwap ++ y:x:afterSwap) $ min textLength (cursor + 1)

    in

    [ keys "Swap letters" [ctrlCharKey 't']
      swapLetters
    | cursor > 0 && textLength >= 2 ],

    [ keys "Delete forward" [specialKey E.KeyDel] $
      delete 1
    | cursor < textLength ],

    [ keys "Delete word forward" [altCharKey 'd']
      deleteWord
    | cursor < textLength ],

    [ keys "Delete rest of line" [ctrlCharKey 'k'] $
      delete (length curLineAfter)
    | not . null $ curLineAfter ],

    [ keys "Delete newline" [ctrlCharKey 'k'] $
      delete 1
    | null curLineAfter && cursor < textLength ],

    [ keys "Delete till beginning of line" [ctrlCharKey 'u'] $
      backDelete (length curLineBefore)
    | not . null $ curLineBefore ],

    [ E.filterChars (`notElem` " \n") .
      E.simpleChars "Character" "Insert character" $
      insert . (: [])
    ],

    [ keys "Insert Newline" [specialKey E.KeyEnter] (insert "\n") ],

    [ keys "Insert Space" [E.ModKey E.noMods E.KeySpace] (insert " ") ]

    ]
  where
    splitLines = splitWhen ((== '\n') . snd)
    linesBefore = reverse (splitLines before)
    linesAfter = splitLines after
    prevLine = linesBefore !! 1
    nextLine = linesAfter !! 1
    curLineBefore = head linesBefore
    curLineAfter = head linesAfter
    cursorX = length curLineBefore
    cursorY = length linesBefore - 1

    eventRes = eventResult myId strWithIds
    moveAbsolute a = eventRes strWithIds . max 0 $ min (length str) a
    moveRelative d = moveAbsolute (cursor + d)
    backDelete n = eventRes (take (cursor-n) strWithIds ++ drop cursor strWithIds) (cursor-n)
    delete n = eventRes (before ++ drop n after) cursor
    insert l = eventRes str' cursor'
      where
        cursor' = cursor + length l
        str' = concat [before, map ((,) Nothing) l, after]

    backDeleteWord = backDelete . length . tillEndOfWord . reverse $ map snd before
    deleteWord = delete . length . tillEndOfWord $ map snd after

    backMoveWord = moveRelative . negate . length . tillEndOfWord . reverse $ map snd before
    moveWord = moveRelative . length . tillEndOfWord $ map snd after

    keys = flip E.keyPresses

    specialKey = E.ModKey E.noMods
    ctrlSpecialKey = E.ModKey E.ctrl
    ctrlCharKey = E.ModKey E.ctrl . E.charKey
    altCharKey = E.ModKey E.alt . E.charKey
    homeKeys = [specialKey E.KeyHome, ctrlCharKey 'A']
    endKeys = [specialKey E.KeyEnd, ctrlCharKey 'E']
    textLength = length str
    lineCount = length $ splitWhen (== '\n') displayStr
    strWithIds = map (first Just) $ enumerate str
    (before, after) = splitAt cursor strWithIds

make :: Style -> Widget.Id -> String -> Widget.Id -> Widget ((,) String)
make style cursor str myId =
  maybe makeUnfocused makeFocused mCursor style str myId
  where
    mCursor = fmap extractTextEditCursor $ Widget.subId myId cursor
    extractTextEditCursor [x] = min (length str) $ BinUtils.decodeS x
    extractTextEditCursor _ = length str
