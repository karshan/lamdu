module Lamdu.Data.Infer.Rule.GetField
  ( make, phase0, phase1, phase2
  ) where

import Control.Lens.Operators
import Control.Monad (void, unless, when)
import Control.Monad.Trans.State (StateT(..))
import Control.MonadA (MonadA)
import Data.Maybe.Utils (unsafeUnjust)
import Data.Store.Guid (Guid)
import Lamdu.Data.Infer.Internal
import Lamdu.Data.Infer.Monad (Infer)
import Lamdu.Data.Infer.RefTags (ExprRef)
import Lamdu.Data.Infer.Rule.Func (RuleResult(..), RuleFunc)
import Lamdu.Data.Infer.Unify (unify)
import qualified Control.Lens as Lens
import qualified Control.Monad.Trans.State as State
import qualified Data.Map as Map
import qualified Data.OpaqueRef as OR
import qualified Data.UnionFind.WithData as UFData
import qualified Lamdu.Data.Expression as Expr
import qualified Lamdu.Data.Expression.Lens as ExprLens
import qualified Lamdu.Data.Infer.Monad as InferM
import qualified Lamdu.Data.Infer.Rule.Monad as RuleMonad
import qualified Lamdu.Data.Infer.Rule.Types as Rule
import qualified Lamdu.Data.Infer.Trigger as Trigger

assertRecordTypeFields :: MonadA m => ExprRef def -> StateT (Context def) m [(ExprRef def, ExprRef def)]
assertRecordTypeFields ref =
  Lens.zoom ctxUFExprs $ UFData.read ref
  <&> (^? rdBody . ExprLens.bodyKindedRecordFields Expr.KType)
  <&> unsafeUnjust "isRecord && not record?!"

handlePotentialMatches ::
  Eq def => [(ExprRef def, ExprRef def)] -> ExprRef def -> ExprRef def ->
  Infer def Bool
handlePotentialMatches fields tag typ =
  case fields of
  [] -> InferM.error InferM.GetMissingField
  [(fieldTag, fieldTyp)] -> do
    void $ unify fieldTag tag
    void $ unify fieldTyp typ
    return True
  _ ->
    return False

assertTag :: MonadA m => ExprRef def -> StateT (Context def) m Guid
assertTag ref =
  Lens.zoom ctxUFExprs $ UFData.read ref
  <&> (^? rdBody . ExprLens.bodyTag)
  <&> unsafeUnjust "isTag && not tag?!"

-- Phase0: Verify record has record type:
phase0 :: Eq def => Rule.GetFieldPhase0 def -> RuleFunc def
phase0 rule triggers =
  case Map.toList triggers of
  [((recordTypeRef, _), isRecord)]
    | isRecord -> do
      recordFields <- InferM.liftContext $ assertRecordTypeFields recordTypeRef
      isFinished <-
        handlePotentialMatches recordFields
        (rule ^. Rule.gf0GetFieldTag)
        (rule ^. Rule.gf0GetFieldType)
      unless isFinished $ do
        phase1RuleRef <-
          InferM.liftRuleMap . Rule.new $
          Rule.RuleGetFieldPhase1 Rule.GetFieldPhase1
          { Rule._gf1GetFieldRecordTypeFields = recordFields
          , Rule._gf1GetFieldType = rule ^. Rule.gf0GetFieldType
          }
        Trigger.add Trigger.IsDirectlyTag phase1RuleRef $
          rule ^. Rule.gf0GetFieldTag
      return RuleDelete
    | otherwise -> InferM.error InferM.GetFieldRequiresRecord
  _ -> error "A singleton trigger must be used with GetFieldPhase0 rule"

-- Phase1: Get GetField's tag
phase1 :: Eq def => Rule.GetFieldPhase1 def -> RuleFunc def
phase1 rule triggers =
  case Map.toList triggers of
  [(_, False)] -> return RuleDelete -- Not a tag in that position, do nothing
  [((getFieldTagRef, _), True)] -> do
    getFieldTag <- InferM.liftContext $ assertTag getFieldTagRef
    phase2RuleRef <-
      InferM.liftRuleMap . Rule.new $
      Rule.RuleGetFieldPhase2 Rule.GetFieldPhase2
        { Rule._gf2Tag = getFieldTag
        , Rule._gf2TagRef = getFieldTagRef
        , Rule._gf2TypeRef = rule ^. Rule.gf1GetFieldType
        , Rule._gf2MaybeMatchers = OR.refMapFromList $ rule ^. Rule.gf1GetFieldRecordTypeFields
        }
    rule ^. Rule.gf1GetFieldRecordTypeFields
      & Lens.traverseOf_ (Lens.traverse . Lens._1) %%~
        Trigger.add Trigger.IsDirectlyTag phase2RuleRef
    return RuleDelete
  _ -> error "Only one trigger before phase 1?!"

-- Phase2: Find relevant record fields by triggered tags
phase2 :: Eq def => Rule.GetFieldPhase2 def -> RuleFunc def
phase2 =
  RuleMonad.run Rule.RuleGetFieldPhase2 handleTrigger
  where
    handleTrigger (_, False) = return ()
    handleTrigger ((ref, _), True) = do
      rep <- RuleMonad.liftInfer . InferM.liftUFExprs $ UFData.find "phase2.ref" ref
      fieldTag <- RuleMonad.liftInfer . InferM.liftContext $ assertTag rep
      mFieldTypeRef <- do
        rule <- State.get
        (mFieldTypeRef, newMaybeMatchers) <-
          RuleMonad.liftInfer . InferM.liftUFExprs $
          OR.refMapUnmaintainedLookup UFData.find rep `runStateT` (rule ^. Rule.gf2MaybeMatchers)
        Rule.gf2MaybeMatchers .= newMaybeMatchers
        return mFieldTypeRef
      tag <- Lens.use Rule.gf2Tag
      if fieldTag == tag
        then do
          let fieldTypeRef = unsafeUnjust "phase2 triggered by wrong ref!" mFieldTypeRef
          RuleMonad.liftInfer . void . unify fieldTypeRef =<< Lens.use Rule.gf2TypeRef
          RuleMonad.ruleDelete
        else do
          Rule.gf2MaybeMatchers . Lens.at rep .= Nothing
          isFinished <- do
            rule <- State.get
            RuleMonad.liftInfer $
              handlePotentialMatches (OR.refMapToList (rule ^. Rule.gf2MaybeMatchers))
              (rule ^. Rule.gf2TagRef)
              (rule ^. Rule.gf2TypeRef)
          when isFinished RuleMonad.ruleDelete

make :: ExprRef def -> ExprRef def -> ExprRef def -> Infer def ()
make tagValRef getFieldTypeRef recordTypeRef = do
  ruleRef <-
    InferM.liftRuleMap . Rule.new $
    Rule.RuleGetFieldPhase0 Rule.GetFieldPhase0
    { Rule._gf0GetFieldTag = tagValRef
    , Rule._gf0GetFieldType = getFieldTypeRef
    }
  Trigger.add Trigger.IsRecordType ruleRef recordTypeRef