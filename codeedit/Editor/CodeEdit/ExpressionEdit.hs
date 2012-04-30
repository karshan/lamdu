{-# LANGUAGE OverloadedStrings #-}
module Editor.CodeEdit.ExpressionEdit(make) where

import Control.Arrow (first)
import Control.Monad (liftM)
import Data.Monoid (Monoid(..))
import Data.Store.IRef (IRef)
import Data.Store.Transaction (Transaction)
import Editor.Anchors (ViewTag)
import Editor.CTransaction (CTransaction, getP)
import Editor.CodeEdit.Ancestry(AncestryItem(..))
import Editor.CodeEdit.ExpressionEdit.ExpressionMaker(ExpressionEditMaker)
import Editor.MonadF (MonadF)
import Graphics.UI.Bottle.Widget (EventHandlers)
import qualified Data.Store.Transaction as Transaction
import qualified Editor.BottleWidgets as BWidgets
import qualified Editor.CodeEdit.Ancestry as Ancestry
import qualified Editor.CodeEdit.ExpressionEdit.ApplyEdit as ApplyEdit
import qualified Editor.CodeEdit.ExpressionEdit.FuncEdit as FuncEdit
import qualified Editor.CodeEdit.ExpressionEdit.HoleEdit as HoleEdit
import qualified Editor.CodeEdit.ExpressionEdit.LiteralEdit as LiteralEdit
import qualified Editor.CodeEdit.ExpressionEdit.VarEdit as VarEdit
import qualified Editor.CodeEdit.ExpressionEdit.WhereEdit as WhereEdit
import qualified Editor.CodeEdit.Parens as Parens
import qualified Editor.CodeEdit.Sugar as Sugar
import qualified Editor.Config as Config
import qualified Editor.Data as Data
import qualified Editor.DataOps as DataOps
import qualified Editor.WidgetIds as WidgetIds
import qualified Graphics.UI.Bottle.Widget as Widget
import qualified Graphics.UI.Bottle.Widgets.FocusDelegator as FocusDelegator

data HoleResultPicker m = NotAHole | IsAHole (Maybe (HoleEdit.ResultPicker m))
foldHolePicker
  :: r -> (Maybe (HoleEdit.ResultPicker m) -> r)
  -> HoleResultPicker m -> r
foldHolePicker notHole _isHole NotAHole = notHole
foldHolePicker _notHole isHole (IsAHole x) = isHole x

make :: MonadF m => ExpressionEditMaker m
make ancestry sExpr = do
  exprI <- getP $ Sugar.rExpressionPtr sExpr
  let
    isAHole = (fmap . liftM . first) IsAHole
    notAHole = (fmap . liftM) ((,) NotAHole)
    wrapNonHoleExpr =
      notAHole .
      BWidgets.wrapDelegatedWithKeys Config.exprFocusDelegatorKeys FocusDelegator.Delegating id
    exprId = WidgetIds.fromIRef exprI
    addParens parensType mkWidget myId =
      mkWidget myId >>= Parens.addParens parensType exprId
    parenify = maybe id addParens (Sugar.rMParensType sExpr)
    makeEditor =
      case Sugar.rExpression sExpr of
      Sugar.ExpressionWhere w ->
        wrapNonHoleExpr . parenify $
          WhereEdit.makeWithBody make ancestry w
      Sugar.ExpressionFunc f ->
        wrapNonHoleExpr . parenify  $ FuncEdit.make make ancestry (Sugar.rExpressionPtr sExpr) f
      Sugar.ExpressionHole holeState ->
        isAHole . maybe id (error "parens on hole?") (Sugar.rMParensType sExpr) $ HoleEdit.make ancestry holeState sExpr
      Sugar.ExpressionGetVariable varRef ->
        notAHole . parenify $ VarEdit.make varRef
      Sugar.ExpressionApply apply ->
        wrapNonHoleExpr . parenify  $ ApplyEdit.make make ancestry (Sugar.rExpressionPtr sExpr) apply
      Sugar.ExpressionLiteralInteger integer ->
        notAHole . parenify $ LiteralEdit.makeInt exprI integer
  (holePicker, widget) <- makeEditor exprId
  eventMap <- expressionEventMap ancestry sExpr holePicker
  return $ Widget.weakerEvents eventMap widget

expressionEventMap
  :: MonadF m
  => Ancestry.ExpressionAncestry m
  -> Sugar.ExpressionRef m
  -> HoleResultPicker m
  -> CTransaction ViewTag m (EventHandlers (Transaction ViewTag m))
expressionEventMap ancestry sExpr holePicker = do
  return . mconcat $
    [ moveUnlessOnHole .
      Widget.actionEventMapMovesCursor
      Config.giveAsArgumentKeys "Give as argument" .
      WidgetIds.diveIn $ DataOps.giveAsArg (Sugar.rExpressionPtr sExpr)
    , moveUnlessOnHole .
      Widget.actionEventMapMovesCursor
      Config.callWithArgumentKeys "Call with argument" .
      WidgetIds.diveIn $ DataOps.callWithArg (Sugar.rExpressionPtr sExpr)
    , pickResultFirst .
      Widget.actionEventMapMovesCursor
      Config.addNextArgumentKeys "Add next arg" . liftM WidgetIds.fromGuid $ Sugar.rAddNextArg sExpr
    , ifHole (const mempty) $ replaceEventMap ancestry (Sugar.rExpressionPtr sExpr)
    , Widget.actionEventMapMovesCursor
      Config.lambdaWrapKeys "Lambda wrap" . WidgetIds.diveIn $
      DataOps.lambdaWrap (Sugar.rExpressionPtr sExpr)
    ]
  where
    moveUnlessOnHole = ifHole $ (const . fmap . liftM . Widget.atECursor . const) Nothing
    pickResultFirst = ifHole $ maybe id (fmap . joinEvents)
    ifHole whenHole = foldHolePicker id whenHole holePicker
    joinEvents x y = do
      r <- liftM Widget.eAnimIdMapping x
      (liftM . Widget.atEAnimIdMapping) (. r) y

replaceEventMap
  :: (Monad m, Functor m)
  => Ancestry.ExpressionAncestry m
  -> Transaction.Property ViewTag m (IRef Data.Expression)
  -> Widget.EventHandlers (Transaction ViewTag m)
replaceEventMap ancestry exprPtr =
  Widget.actionEventMapMovesCursor
  (Config.replaceKeys ++ extraReplaceKeys) "Replace" . WidgetIds.diveIn $
  DataOps.replaceWithHole exprPtr
  where
    extraReplaceKeys =
      case ancestry of
        (AncestryItemApply _ : _) -> []
        _ -> Config.delKeys
