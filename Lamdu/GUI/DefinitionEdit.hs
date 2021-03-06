{-# LANGUAGE OverloadedStrings #-}
module Lamdu.GUI.DefinitionEdit
  ( make
  , diveToNameEdit
  ) where

import           Control.Applicative ((<$>))
import qualified Control.Lens as Lens
import           Control.Lens.Operators
import           Control.Lens.Tuple
import           Control.MonadA (MonadA)
import           Data.Store.Transaction (Transaction)
import           Data.Traversable (sequenceA)
import           Data.Vector.Vector2 (Vector2(..))
import qualified Graphics.DrawingCombinators as Draw
import qualified Graphics.UI.Bottle.Animation as Anim
import qualified Graphics.UI.Bottle.EventMap as E
import           Graphics.UI.Bottle.View (View(..))
import           Graphics.UI.Bottle.Widget (Widget)
import qualified Graphics.UI.Bottle.Widget as Widget
import qualified Graphics.UI.Bottle.Widgets.Box as Box
import           Lamdu.Config (Config)
import qualified Lamdu.Config as Config
import qualified Lamdu.Data.Anchors as Anchors
import qualified Lamdu.Data.Definition as Definition
import           Lamdu.Expr.Scheme (Scheme(..), schemeType)
import qualified Graphics.UI.Bottle.Widgets as BWidgets
import           Lamdu.GUI.CodeEdit.Settings (Settings)
import qualified Lamdu.GUI.ExpressionEdit as ExpressionEdit
import qualified Lamdu.GUI.ExpressionEdit.BinderEdit as BinderEdit
import qualified Lamdu.GUI.ExpressionEdit.BuiltinEdit as BuiltinEdit
import qualified Lamdu.GUI.ExpressionGui as ExpressionGui
import           Lamdu.GUI.ExpressionGui.Monad (ExprGuiM)
import qualified Lamdu.GUI.ExpressionGui.Monad as ExprGuiM
import           Graphics.UI.Bottle.WidgetsEnvT (WidgetEnvT)
import qualified Lamdu.GUI.WidgetIds as WidgetIds
import           Lamdu.Sugar.AddNames.Types (Name(..), DefinitionN)
import           Lamdu.Sugar.NearestHoles (NearestHoles)
import qualified Lamdu.Sugar.Types as Sugar

type T = Transaction

toExprGuiMPayload :: ([Sugar.EntityId], NearestHoles) -> ExprGuiM.Payload
toExprGuiMPayload (entityIds, nearestHoles) =
  ExprGuiM.emptyPayload nearestHoles & ExprGuiM.plStoredEntityIds .~ entityIds

make ::
  MonadA m => Anchors.CodeProps m -> Config -> Settings ->
  DefinitionN m ([Sugar.EntityId], NearestHoles) ->
  WidgetEnvT (T m) (Widget (T m))
make cp config settings defS =
  ExprGuiM.run ExpressionEdit.make cp config settings $
  case exprGuiDefS ^. Sugar.drBody of
    Sugar.DefinitionBodyExpression bodyExpr ->
      makeExprDefinition exprGuiDefS bodyExpr
    Sugar.DefinitionBodyBuiltin builtin ->
      makeBuiltinDefinition exprGuiDefS builtin
  where
    exprGuiDefS =
      defS
      <&> Lens.mapped %~ toExprGuiMPayload
      <&> ExprGuiM.markRedundantTypes

topLevelSchemeTypeView :: MonadA m => Widget.R -> Sugar.EntityId -> Scheme -> ExprGuiM m (Widget f)
topLevelSchemeTypeView minWidth entityId scheme =
  -- At the definition-level, Schemes can be shown as ordinary
  -- types to avoid confusing forall's:
  ExpressionGui.makeTypeView minWidth entityId (scheme ^. schemeType)

makeBuiltinDefinition ::
  MonadA m =>
  Sugar.Definition (Name m) m (ExprGuiM.SugarExpr m) ->
  Sugar.DefinitionBuiltin m -> ExprGuiM m (Widget (T m))
makeBuiltinDefinition def builtin =
  Box.vboxAlign 0 <$> sequenceA
  [ sequenceA
    [ ExpressionGui.makeNameOriginEdit name (Widget.joinId myId ["name"])
    , ExprGuiM.makeLabel "=" $ Widget.toAnimId myId
    , BuiltinEdit.make builtin myId
    ]
    >>= ExprGuiM.widgetEnv . BWidgets.hboxCenteredSpaced
  , topLevelSchemeTypeView 0 entityId
    (builtin ^. Sugar.biType)
  ]
  where
    name = def ^. Sugar.drName
    entityId = def ^. Sugar.drEntityId
    myId = WidgetIds.fromEntityId entityId

typeIndicatorId :: Widget.Id -> Widget.Id
typeIndicatorId myId = Widget.joinId myId ["type indicator"]

typeIndicator ::
  MonadA m => Widget.R -> Draw.Color -> Widget.Id -> ExprGuiM m (Widget f)
typeIndicator width color myId =
  do
    config <- ExprGuiM.readConfig
    let
      typeIndicatorHeight =
        realToFrac $ Config.typeIndicatorFrameWidth config ^. _2
    Anim.unitSquare (Widget.toAnimId (typeIndicatorId myId))
      & View 1
      & Widget.fromView
      & Widget.scale (Vector2 width typeIndicatorHeight)
      & Widget.tint color
      & return

acceptableTypeIndicator ::
  (MonadA m, MonadA f) =>
  Widget.R -> f a -> Draw.Color -> Widget.Id ->
  ExprGuiM m (Widget f)
acceptableTypeIndicator width accept color myId =
  do
    config <- ExprGuiM.readConfig
    let
      acceptKeyMap =
        Widget.keysEventMapMovesCursor (Config.acceptDefinitionTypeKeys config)
        (E.Doc ["Edit", "Accept inferred type"]) (accept >> return myId)
    typeIndicator width color myId
      <&> Widget.weakerEvents acceptKeyMap
      >>= ExprGuiM.widgetEnv . BWidgets.makeFocusableView (typeIndicatorId myId)

makeExprDefinition ::
  MonadA m =>
  Sugar.Definition (Name m) m (ExprGuiM.SugarExpr m) ->
  Sugar.DefinitionExpression (Name m) m (ExprGuiM.SugarExpr m) ->
  ExprGuiM m (Widget (T m))
makeExprDefinition def bodyExpr = do
  config <- ExprGuiM.readConfig
  bodyWidget <-
    BinderEdit.make (def ^. Sugar.drName)
    (bodyExpr ^. Sugar.deContent) myId
    <&> (^. ExpressionGui.egWidget)
  let width = bodyWidget ^. Widget.width
  vspace <- BWidgets.verticalSpace & ExprGuiM.widgetEnv
  typeWidget <-
    fmap (Box.vboxAlign 0.5 . concatMap (\w -> [vspace, w])) $
    case bodyExpr ^. Sugar.deTypeInfo of
    Sugar.DefinitionExportedTypeInfo scheme ->
      sequence $
      typeIndicator width (Config.typeIndicatorMatchColor config) myId :
      [ topLevelSchemeTypeView width entityId scheme
      | Lens.hasn't (Sugar.deContent . Sugar.dParams . Sugar._NoParams) bodyExpr
      ]
    Sugar.DefinitionNewType (Sugar.AcceptNewType oldScheme _ accept) ->
      sequence $
      case oldScheme of
      Definition.NoExportedType ->
        [ acceptableTypeIndicator width accept (Config.acceptDefinitionTypeForFirstTimeColor config) myId
        ]
      Definition.ExportedType scheme ->
        [ acceptableTypeIndicator width accept (Config.typeIndicatorErrorColor config) myId
        , topLevelSchemeTypeView width entityId scheme
        ]
  return $ Box.vboxAlign 0 [bodyWidget, typeWidget]
  where
    entityId = def ^. Sugar.drEntityId
    myId = WidgetIds.fromEntityId entityId

diveToNameEdit :: Widget.Id -> Widget.Id
diveToNameEdit = BinderEdit.diveToNameEdit
