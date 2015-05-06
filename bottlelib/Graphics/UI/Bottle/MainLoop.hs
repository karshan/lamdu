{-# LANGUAGE CPP, RecordWildCards #-}
module Graphics.UI.Bottle.MainLoop
    ( mainLoopAnim
    , mainLoopImage
    , mainLoopWidget
    ) where

import           Control.Applicative ((<$>))
import           Control.Concurrent (forkIO, threadDelay, killThread, myThreadId)
import           Control.Concurrent.STM.TVar
import           Control.Exception (bracket, onException)
import           Control.Lens (Lens')
import           Control.Lens.Operators
import           Control.Monad (when, unless, forever)
import qualified Control.Monad.STM as STM
import           Data.IORef
import           Data.MRUMemo (memoIO)
import           Data.Monoid (Monoid(..), (<>))
import qualified Data.Monoid as Monoid
import           Data.Time.Clock (UTCTime, getCurrentTime, diffUTCTime)
import           Data.Traversable (traverse, sequenceA)
import           Data.Vector.Vector2 (Vector2(..))
import           Graphics.DrawingCombinators ((%%))
import           Graphics.DrawingCombinators.Utils (Image)
import qualified Graphics.DrawingCombinators.Utils as DrawUtils
import           Graphics.Rendering.OpenGL.GL (($=))
import qualified Graphics.Rendering.OpenGL.GL as GL
import           Graphics.UI.Bottle.Animation (AnimId)
import qualified Graphics.UI.Bottle.Animation as Anim
import qualified Graphics.UI.Bottle.EventMap as E
import           Graphics.UI.Bottle.Widget (Widget)
import qualified Graphics.UI.Bottle.Widget as Widget
import qualified Graphics.UI.GLFW as GLFW
import           Graphics.UI.GLFW.Events (KeyEvent, Event(..), Result(..), eventLoop)

data ImageHandlers = ImageHandlers
  { imageEventHandler :: KeyEvent -> IO ()
  , imageUpdate :: IO (Maybe Image)
  , imageRefresh :: IO Image
  }

windowSize :: GLFW.Window -> IO Widget.Size
windowSize win =
    do
        (x, y) <- GLFW.getFramebufferSize win
        return $ fromIntegral <$> Vector2 x y

data EventResult =
    ERNone | ERRefresh | ERQuit
    deriving (Eq, Ord, Show)
instance Monoid EventResult where
    mempty = ERNone
    mappend = max

mainLoopImage :: GLFW.Window -> (Widget.Size -> ImageHandlers) -> IO ()
mainLoopImage win imageHandlers =
    eventLoop win handleEvents
    where
        handleEvent handlers (EventKey keyEvent) =
            do
                imageEventHandler handlers keyEvent
                return ERNone
        handleEvent _ EventWindowClose = return ERQuit
        handleEvent _ EventWindowRefresh = return ERRefresh

        handleEvents events =
            do
                winSize <- windowSize win
                let handlers = imageHandlers winSize
                eventResult <- mconcat <$> traverse (handleEvent handlers) events
                case eventResult of
                    ERQuit -> return ResultQuit
                    ERRefresh -> imageRefresh handlers >>= draw winSize
                    ERNone -> imageUpdate handlers >>= maybe delay (draw winSize)
        delay =
            do
                -- TODO: If we can verify that there's sync-to-vblank, we
                -- need no sleep here
                threadDelay 10000
                return ResultNone
        draw winSize@(Vector2 winSizeX winSizeY) image =
            do
                GL.viewport $=
                    (GL.Position 0 0,
                     GL.Size (round winSizeX) (round winSizeY))
                image
                    & (DrawUtils.translate (Vector2 (-1) 1) <>
                       DrawUtils.scale (Vector2 (2/winSizeX) (-2/winSizeY)) %%)
                    & let Vector2 glPixelRatioX glPixelRatioY = winSize / 2 -- GL range is -1..1
                      in DrawUtils.clearRenderSized (glPixelRatioX, glPixelRatioY)
                return ResultDidDraw

data AnimHandlers = AnimHandlers
    { animTickHandler :: IO (Maybe (Monoid.Endo AnimId))
    , animEventHandler :: KeyEvent -> IO (Maybe (Monoid.Endo AnimId))
    , animMakeFrame :: IO Anim.Frame
    }

data IsAnimating = Animating | NotAnimating
    deriving Eq

withForkedIO :: IO () -> IO a -> IO a
withForkedIO action = bracket (forkIO action) killThread . const

-- Animation thread will have not only the cur frame, but the dest
-- frame in its mutable current state (to update it asynchronously)

-- Worker thread receives events, ticks (which may be lost), handles them, responds to animation thread
-- Animation thread sends events, ticks to worker thread. Samples results from worker thread, applies them to the cur state

data AnimState = AnimState
    { _asIsAnimating :: !IsAnimating
    , _asCurTime :: !UTCTime
    , _asCurFrame :: !Anim.Frame
    , _asDestFrame :: !Anim.Frame
    }

asIsAnimating :: Lens' AnimState IsAnimating
asIsAnimating f AnimState {..} = f _asIsAnimating <&> \_asIsAnimating -> AnimState {..}

asCurFrame :: Lens' AnimState Anim.Frame
asCurFrame f AnimState {..} = f _asCurFrame <&> \_asCurFrame -> AnimState {..}

asDestFrame :: Lens' AnimState Anim.Frame
asDestFrame f AnimState {..} = f _asDestFrame <&> \_asDestFrame -> AnimState {..}

data ThreadSyncVar = ThreadSyncVar
    { _tsvHaveTicks :: Bool
    , _tsvWinSize :: Widget.Size
    , _tsvReversedEvents :: [KeyEvent]
    }

initialAnimState :: Anim.Frame -> IO AnimState
initialAnimState initialFrame =
    do
        curTime <- getCurrentTime
        return AnimState
            { _asIsAnimating = Animating
            , _asCurTime = curTime
            , _asCurFrame = initialFrame
            , _asDestFrame = initialFrame
            }

tsvHaveTicks :: Lens' ThreadSyncVar Bool
tsvHaveTicks f ThreadSyncVar {..} = f _tsvHaveTicks <&> \_tsvHaveTicks -> ThreadSyncVar {..}

tsvWinSize :: Lens' ThreadSyncVar Widget.Size
tsvWinSize f ThreadSyncVar {..} = f _tsvWinSize <&> \_tsvWinSize -> ThreadSyncVar {..}

tsvReversedEvents :: Lens' ThreadSyncVar [KeyEvent]
tsvReversedEvents f ThreadSyncVar {..} = f _tsvReversedEvents <&> \_tsvReversedEvents -> ThreadSyncVar {..}

atomicModifyIORef_ :: IORef a -> (a -> a) -> IO ()
atomicModifyIORef_ ioref f = atomicModifyIORef ioref (flip (,) () . f)

killSelfOnError :: IO a -> IO (IO a)
killSelfOnError action =
    do
        selfId <- myThreadId
        return $ action `onException` killThread selfId

mainLoopAnim :: GLFW.Window -> IO Anim.R -> (Widget.Size -> AnimHandlers) -> IO ()
mainLoopAnim win getAnimationHalfLife animHandlers =
    do
        initialWinSize <- windowSize win
        frameStateVar <-
            animMakeFrame (animHandlers initialWinSize)
            >>= initialAnimState >>= newIORef
        eventTVar <-
            STM.atomically $ newTVar ThreadSyncVar
            { _tsvHaveTicks = False
            , _tsvWinSize = initialWinSize
            , _tsvReversedEvents = []
            }
        eventHandler <- killSelfOnError (eventHandlerThread frameStateVar eventTVar animHandlers)
        withForkedIO eventHandler $
            mainLoopAnimThread frameStateVar eventTVar win getAnimationHalfLife

eventHandlerThread :: IORef AnimState -> TVar ThreadSyncVar -> (Widget.Size -> AnimHandlers) -> IO ()
eventHandlerThread frameStateVar eventTVar animHandlers =
    forever $
    do
        tsv <-
            do
                tsv <- readTVar eventTVar
                when (not (tsv ^. tsvHaveTicks) && null (tsv ^. tsvReversedEvents)) $
                    STM.retry
                tsv
                    & tsvHaveTicks .~ False
                    & tsvReversedEvents .~ []
                    & writeTVar eventTVar
                return tsv
            & STM.atomically
        let handlers = animHandlers (tsv ^. tsvWinSize)
        eventResults <-
            mapM (animEventHandler handlers) $ reverse (tsv ^. tsvReversedEvents)
        tickResult <-
            if tsv ^. tsvHaveTicks
            then animTickHandler handlers
            else return Nothing
        case mconcat (tickResult : eventResults) of
            Nothing -> return ()
            Just mapping ->
                do
                    destFrame <- animMakeFrame handlers
                    atomicModifyIORef_ frameStateVar $
                        \oldFrameState ->
                        oldFrameState
                        & asIsAnimating .~ Animating
                        & asDestFrame .~ destFrame
                        & asCurFrame %~ Anim.mapIdentities (Monoid.appEndo mapping)

mainLoopAnimThread ::
    IORef AnimState -> TVar ThreadSyncVar -> GLFW.Window -> IO Widget.R -> IO ()
mainLoopAnimThread frameStateVar eventTVar win getAnimationHalfLife =
    mainLoopImage win $ \size ->
        ImageHandlers
        { imageEventHandler = \event ->
              STM.atomically $ modifyTVar eventTVar $ tsvReversedEvents %~ (event :)
        , imageRefresh =
            do
                atomicModifyIORef_ frameStateVar $ asIsAnimating .~ Animating
                updateFrameState size <&> _asCurFrame <&> Anim.draw
        , imageUpdate = updateFrameState size <&> frameStateResult
        }
    where
        tick size =
            STM.atomically $ modifyTVar eventTVar $
            (tsvHaveTicks .~ True) . (tsvWinSize .~ size)
        updateFrameState size =
            do
                tick size
                curTime <- getCurrentTime
                animationHalfLife <- getAnimationHalfLife
                atomicModifyIORef frameStateVar $
                    \(AnimState prevAnimating prevTime prevFrame destFrame) ->
                    let newAnimState =
                            case prevAnimating of
                            NotAnimating ->
                                AnimState NotAnimating curTime prevFrame destFrame
                            Animating ->
                                case Anim.nextFrame progress destFrame prevFrame of
                                Nothing -> AnimState NotAnimating curTime destFrame destFrame
                                Just newFrame -> AnimState Animating curTime newFrame destFrame
                                where
                                    elapsed = realToFrac (curTime `diffUTCTime` prevTime)
                                    progress = 1 - 0.5 ** (elapsed / animationHalfLife)
                    in (newAnimState, newAnimState)
        frameStateResult (AnimState isAnimating _ frame _)
            | Animating == isAnimating = Just $ Anim.draw frame
            | otherwise = Nothing

mainLoopWidget :: GLFW.Window -> IO Bool -> (Widget.Size -> IO (Widget IO)) -> IO Anim.R -> IO ()
mainLoopWidget win widgetTickHandler mkWidgetUnmemod getAnimationHalfLife =
    do
        mkWidgetRef <- newIORef =<< memoIO mkWidgetUnmemod
        let newWidget = writeIORef mkWidgetRef =<< memoIO mkWidgetUnmemod
            getWidget size = ($ size) =<< readIORef mkWidgetRef
        mainLoopAnim win getAnimationHalfLife $ \size -> AnimHandlers
            { animTickHandler =
                do
                    anyUpdate <- widgetTickHandler
                    when anyUpdate newWidget
                    widget <- getWidget size
                    tickResults <-
                        sequenceA (widget ^. Widget.eventMap . E.emTickHandlers)
                    unless (null tickResults) newWidget
                    return $
                        case (tickResults, anyUpdate) of
                        ([], False) -> Nothing
                        _ -> Just . mconcat $ map (^. Widget.eAnimIdMapping) tickResults
            , animEventHandler = \event ->
                do
                    widget <- getWidget size
                    mAnimIdMapping <-
                        (traverse . fmap) (^. Widget.eAnimIdMapping) .
                        E.lookup event $ widget ^. Widget.eventMap
                    case mAnimIdMapping of
                        Nothing -> return ()
                        Just _ -> newWidget
                    return mAnimIdMapping
            , animMakeFrame = getWidget size <&> (^. Widget.animFrame)
            }
