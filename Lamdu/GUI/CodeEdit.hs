{-# LANGUAGE DeriveFunctor, DeriveFoldable, DeriveTraversable #-}
{-# LANGUAGE RecordWildCards, OverloadedStrings, TypeFamilies #-}
module Lamdu.GUI.CodeEdit
  ( make
  , Env(..)
  ) where

import           Control.Applicative ((<$>), (<*>))
import qualified Control.Lens as Lens
import           Control.Lens.Operators
import           Control.Lens.Tuple
import           Control.Monad.Trans.Class (lift)
import           Control.MonadA (MonadA)
import           Data.Foldable (Foldable)
import           Data.List.Utils (insertAt, removeAt)
import           Data.Maybe (listToMaybe)
import           Data.Monoid (Monoid(..))
import           Data.Store.Guid (Guid)
import qualified Data.Store.IRef as IRef
import           Data.Store.Property (Property(..))
import           Data.Store.Transaction (Transaction)
import qualified Data.Store.Transaction as Transaction
import           Data.Traversable (Traversable, traverse)
import qualified Graphics.UI.Bottle.EventMap as E
import           Graphics.UI.Bottle.ModKey (ModKey(..))
import           Graphics.UI.Bottle.Widget (Widget)
import qualified Graphics.UI.Bottle.Widget as Widget
import qualified Graphics.UI.Bottle.Widgets as BWidgets
import qualified Graphics.UI.Bottle.Widgets.Box as Box
import qualified Graphics.UI.Bottle.Widgets.Spacer as Spacer
import           Graphics.UI.Bottle.WidgetsEnvT (WidgetEnvT)
import qualified Graphics.UI.Bottle.WidgetsEnvT as WE
import qualified Graphics.UI.GLFW as GLFW
import           Lamdu.Config (Config)
import qualified Lamdu.Config as Config
import qualified Lamdu.Data.Anchors as Anchors
import qualified Lamdu.Data.Ops as DataOps
import           Lamdu.Expr.IRef (DefI)
import           Lamdu.Expr.Load (loadDef)
import           Lamdu.GUI.CodeEdit.Settings (Settings)
import qualified Lamdu.GUI.DefinitionEdit as DefinitionEdit
import qualified Lamdu.GUI.WidgetIds as WidgetIds
import qualified Lamdu.Sugar.AddNames as AddNames
import           Lamdu.Sugar.AddNames.Types (DefinitionN)
import qualified Lamdu.Sugar.Convert as SugarConvert
import qualified Lamdu.Sugar.NearestHoles as NearestHoles
import qualified Lamdu.Sugar.OrderTags as OrderTags
import qualified Lamdu.Sugar.Types as Sugar

type T = Transaction

data Pane m = Pane
  { paneDefI :: DefI m
  , paneDel :: Maybe (T m Guid)
  , paneMoveDown :: Maybe (T m ())
  , paneMoveUp :: Maybe (T m ())
  }

data Env m = Env
  { codeProps :: Anchors.CodeProps m
  , totalSize :: Widget.Size
  , config :: Config
  , settings :: Settings
  }

totalWidth :: Env m -> Widget.R
totalWidth = (^. _1) . totalSize

makePanes :: MonadA m => Transaction.Property m [DefI m] -> Guid -> [Pane m]
makePanes (Property panes setPanes) rootGuid =
  panes ^@.. Lens.traversed <&> convertPane
  where
    mkMDelPane i
      | not (null panes) = Just $ do
        let newPanes = removeAt i panes
        setPanes newPanes
        return . maybe rootGuid IRef.guid . listToMaybe . reverse $
          take (i+1) newPanes
      | otherwise = Nothing
    movePane oldIndex newIndex = do
      let
        (before, item:after) = splitAt oldIndex panes
        newPanes = insertAt newIndex item $ before ++ after
      setPanes newPanes
    mkMMovePaneDown i
      | i+1 < length panes = Just $ movePane i (i+1)
      | otherwise = Nothing
    mkMMovePaneUp i
      | i-1 >= 0 = Just $ movePane i (i-1)
      | otherwise = Nothing
    convertPane (i, defI) = Pane
      { paneDefI = defI
      , paneDel = mkMDelPane i
      , paneMoveDown = mkMMovePaneDown i
      , paneMoveUp = mkMMovePaneUp i
      }

type ProcessedDef m = DefinitionN m ([Sugar.EntityId], NearestHoles.NearestHoles)

makeClipboardsEdit ::
  MonadA m => Env m ->
  [ProcessedDef m] ->
  WidgetEnvT (T m) (Widget (T m))
makeClipboardsEdit env clipboards = do
  clipboardsEdits <- traverse (makePaneWidget env) clipboards
  clipboardTitle <-
    if null clipboardsEdits
    then return Widget.empty
    else BWidgets.makeTextViewWidget "Clipboards:" ["clipboards title"]
  return . Box.vboxAlign 0 $ clipboardTitle : clipboardsEdits

getClipboards :: MonadA m => Anchors.CodeProps m -> T m [DefI m]
getClipboards = Transaction.getP . Anchors.clipboards

processDefI ::
  MonadA m => Env m -> DefI m -> T m (DefinitionN m [Sugar.EntityId])
processDefI env defI =
  loadDef defI
  >>= SugarConvert.convertDefI (codeProps env)
  >>= OrderTags.orderDef
  >>= AddNames.addToDef

processPane ::
  MonadA m => Env m -> Pane m ->
  T m (Pane m, DefinitionN m [Sugar.EntityId])
processPane env pane =
  processDefI env (paneDefI pane)
  <&> (,) pane

type PanesAndClipboards name m a =
    PanesAndClipboardsP name m (Sugar.Expression name m a)
data PanesAndClipboardsP name m expr =
  PanesAndClipboards
  { _panes :: [(Pane m, Sugar.Definition name m expr)]
  , _clipboards :: [Sugar.Definition name m expr]
  } deriving (Functor, Foldable, Traversable)

addNearestHoles ::
  MonadA m =>
  PanesAndClipboards name m [Sugar.EntityId] ->
  PanesAndClipboards name m ([Sugar.EntityId], NearestHoles.NearestHoles)
addNearestHoles pcs =
  pcs
  <&> Lens.mapped %~ (,)
  & NearestHoles.add traverse

make :: MonadA m => Env m -> Guid -> WidgetEnvT (T m) (Widget (T m))
make env rootGuid = do
  prop <- lift $ Anchors.panes (codeProps env) ^. Transaction.mkProperty

  let sugarPanes = makePanes prop rootGuid
  sugarClipboards <- lift $ getClipboards $ codeProps env

  PanesAndClipboards loadedPanes loadedClipboards <-
    PanesAndClipboards
    <$> traverse (processPane env) sugarPanes
    <*> traverse (processDefI env) sugarClipboards
    & lift
    <&> addNearestHoles

  panesEdit <- makePanesEdit env loadedPanes $ WidgetIds.fromGuid rootGuid
  clipboardsEdit <- makeClipboardsEdit env loadedClipboards

  return $
    Box.vboxAlign 0
    [ panesEdit
    , clipboardsEdit
    ]

makeNewDefinitionEventMap ::
  MonadA m => Anchors.CodeProps m ->
  WidgetEnvT (T m) ([ModKey] -> Widget.EventHandlers (T m))
makeNewDefinitionEventMap cp = do
  curCursor <- WE.readCursor
  let
    newDefinition =
      do
        newDefI <- DataOps.newPublicDefinition cp ""
        DataOps.newPane cp newDefI
        DataOps.savePreJumpPosition cp curCursor
        return . DefinitionEdit.diveToNameEdit $ WidgetIds.fromIRef newDefI
  return $ \newDefinitionKeys ->
    Widget.keysEventMapMovesCursor newDefinitionKeys
    (E.Doc ["Edit", "New definition"]) newDefinition

makePanesEdit ::
  MonadA m => Env m -> [(Pane m, ProcessedDef m)] ->
  Widget.Id -> WidgetEnvT (T m) (Widget (T m))
makePanesEdit env loadedPanes myId =
  do
    panesWidget <-
      case loadedPanes of
      [] ->
        makeNewDefinitionAction
        & WE.assignCursor myId newDefinitionActionId
      ((firstPane, _):_) ->
        do
          newDefinitionAction <- makeNewDefinitionAction
          loadedPanes
            & traverse (makePaneEdit env Config.Pane{..})
            <&> concatMap addSpacerAfter
            <&> (++ [newDefinitionAction])
            <&> Box.vboxAlign 0
        & (WE.assignCursor myId . WidgetIds.fromIRef . paneDefI) firstPane
    eventMap <- panesEventMap env
    panesWidget
      & Widget.weakerEvents eventMap
      & return
  where
    newDefinitionActionId = Widget.joinId myId ["NewDefinition"]
    makeNewDefinitionAction =
      do
        newDefinitionEventMap <- makeNewDefinitionEventMap (codeProps env)
        BWidgets.makeFocusableTextView "New..." newDefinitionActionId
          & WE.localEnv (WE.setTextColor newDefinitionActionColor)
          <&> Widget.weakerEvents
              (newDefinitionEventMap [ModKey mempty GLFW.Key'Enter])
    addSpacerAfter x = [x, Spacer.makeWidget 50]
    Config.Pane{..} = Config.pane $ config env

makePaneEdit ::
  MonadA m =>
  Env m -> Config.Pane -> (Pane m, ProcessedDef m) ->
  WidgetEnvT (T m) (Widget (T m))
makePaneEdit env Config.Pane{..} (pane, defS) =
  makePaneWidget env defS
  <&> Widget.weakerEvents paneEventMap
  where
    paneEventMap =
      [ maybe mempty
        (Widget.keysEventMapMovesCursor paneCloseKeys
         (E.Doc ["View", "Pane", "Close"]) . fmap WidgetIds.fromGuid) $ paneDel pane
      , maybe mempty
        (Widget.keysEventMap paneMoveDownKeys
         (E.Doc ["View", "Pane", "Move down"])) $ paneMoveDown pane
      , maybe mempty
        (Widget.keysEventMap paneMoveUpKeys
         (E.Doc ["View", "Pane", "Move up"])) $ paneMoveUp pane
      ] & mconcat

panesEventMap ::
  MonadA m => Env m -> WidgetEnvT (T m) (Widget.EventHandlers (T m))
panesEventMap Env{..} =
  do
    mJumpBack <- lift $ DataOps.jumpBack codeProps
    newDefinitionEventMap <- makeNewDefinitionEventMap codeProps
    return $ mconcat
      [ newDefinitionEventMap newDefinitionKeys
      , maybe mempty
        (Widget.keysEventMapMovesCursor (Config.previousCursorKeys config)
         (E.Doc ["Navigation", "Go back"])) mJumpBack
      ]
  where
    Config.Pane{..} = Config.pane config

makePaneWidget ::
  MonadA m => Env m -> ProcessedDef m -> WidgetEnvT (T m) (Widget (T m))
makePaneWidget env defS =
  DefinitionEdit.make (codeProps env) (config env) (settings env) defS
    <&> fitToWidth (totalWidth env) . colorize
  where
    Config.Pane{..} = Config.pane (config env)
    colorize widget
      | widget ^. Widget.isFocused = colorizeActivePane widget
      | otherwise = colorizeInactivePane widget
    colorizeActivePane =
      Widget.backgroundColor
      (Config.layerActivePane (Config.layers (config env)))
      WidgetIds.activePaneBackground paneActiveBGColor
    colorizeInactivePane = Widget.tint paneInactiveTintColor

fitToWidth :: Widget.R -> Widget f -> Widget f
fitToWidth width w
  | ratio < 1 = w & Widget.scale (realToFrac ratio)
  | otherwise = w
  where
    ratio = width / w ^. Widget.width
