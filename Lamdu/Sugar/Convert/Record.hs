module Lamdu.Sugar.Convert.Record
  ( convertEmpty, convertExtend
  ) where

import Control.Applicative ((<$>))
import Control.Lens.Operators
import Control.Monad (void)
import Control.MonadA (MonadA)
import Data.Maybe (fromMaybe)
import Data.Monoid (Monoid(..))
import Data.Store.Guid (Guid)
import Data.Store.Transaction (Transaction)
import Lamdu.Data.Anchors (assocTagOrder)
import Lamdu.Expr.Val (Val(..))
import Lamdu.Sugar.Convert.Expression.Actions (addActions)
import Lamdu.Sugar.Convert.Monad (ConvertM)
import Lamdu.Sugar.Internal
import Lamdu.Sugar.Types
import qualified Control.Lens as Lens
import qualified Data.Store.Property as Property
import qualified Data.Store.Transaction as Transaction
import qualified Lamdu.Data.Ops as DataOps
import qualified Lamdu.Expr.IRef as ExprIRef
import qualified Lamdu.Expr.Type as T
import qualified Lamdu.Expr.UniqueId as UniqueId
import qualified Lamdu.Expr.Val as V
import qualified Lamdu.Sugar.Convert.Input as Input
import qualified Lamdu.Sugar.Convert.Monad as ConvertM
import qualified Lamdu.Sugar.Internal.EntityId as EntityId

plValI :: Lens.Traversal' (Input.Payload m a) (ExprIRef.ValI m)
plValI = Input.mStored . Lens._Just . Property.pVal

convertTag :: EntityId -> T.Tag -> TagG Guid
convertTag inst tag = TagG inst tag $ UniqueId.toGuid tag

convertField ::
  (MonadA m, Monoid a) =>
  Maybe (ExprIRef.ValIProperty m) ->
  Maybe (ExprIRef.ValI m) -> Record name m (ExpressionU m a) ->
  EntityId -> T.Tag -> Val (Input.Payload m a) ->
  ConvertM m (RecordField Guid m (ExpressionU m a))
convertField mStored mRestI restS inst tag expr = do
  exprS <- ConvertM.convertSubexpression expr
  typeProtect <- ConvertM.typeProtectTransaction
  protectedSetToVal <- ConvertM.typeProtectedSetToVal
  return RecordField
    { _rfTag = convertTag inst tag
    , _rfExpr = exprS
    , _rfMDelete =
        do
          stored <- mStored
          restI <- mRestI
          exprI <- expr ^? V.payload . plValI
          return $
            if null (restS ^. rItems)
            then
              fmap EntityId.ofValI $ protectedSetToVal stored =<<
              case restS ^. rTail of
              ClosedRecord{}
                | Lens.has (rBody . _BodyHole) exprS ->
                    ExprIRef.newVal $ Val () $ V.BLeaf V.LRecEmpty
                | otherwise ->
                    -- When deleting closed one field record
                    -- we replace the record with the field value
                    -- (unless it is a hole)
                    return exprI
              RecordExtending{} -> return restI
            else do
              let delete = DataOps.replace stored restI
              mResult <- fmap EntityId.ofValI <$> typeProtect delete
              case mResult of
                Just result -> return result
                Nothing ->
                  fromMaybe (error "should have a way to fix type error") $
                  case restS ^. rTail of
                  RecordExtending ext ->
                    ext ^? rPayload . plActions . Lens._Just . wrap . _WrapAction
                    <&> fmap snd
                  ClosedRecord mOpen -> (delete >>) <$> mOpen
    }

makeAddField :: MonadA m =>
  ExprIRef.ValIProperty m ->
  ConvertM m (Transaction m RecordAddFieldResult)
makeAddField stored =
  do
    typeProtect <- ConvertM.typeProtectTransaction
    do
      mResultI <- DataOps.recExtend stored & typeProtect
      case mResultI of
        Just extendRes -> return extendRes
        Nothing -> do
          extendRes <- DataOps.recExtend stored
          DataOps.setToWrapper (DataOps.rerResult extendRes) stored & void
          return extendRes
        <&> result
      & return
  where
    result (DataOps.RecExtendResult tag newValI resultI) =
      RecordAddFieldResult
      { _rafrNewTag = TagG (EntityId.ofRecExtendTag resultEntity) tag ()
      , _rafrNewVal = EntityId.ofValI newValI
      , _rafrRecExtend = resultEntity
      }
      where
        resultEntity = EntityId.ofValI resultI

convertEmpty :: MonadA m => Input.Payload m a -> ConvertM m (ExpressionU m a)
convertEmpty exprPl = do
  mAddField <- exprPl ^. Input.mStored & Lens._Just %%~ makeAddField
  BodyRecord Record
    { _rItems = []
    , _rTail =
        exprPl ^. Input.mStored
        <&> DataOps.replaceWithHole
        <&> Lens.mapped %~ EntityId.ofValI
        & ClosedRecord
    , _rMAddField = mAddField
    }
    & addActions exprPl

setTagOrder ::
  MonadA m => Int -> RecordAddFieldResult -> Transaction m RecordAddFieldResult
setTagOrder i r =
  do
    Transaction.setP (assocTagOrder (r ^. rafrNewTag . tagVal)) i
    return r

convertExtend ::
  (MonadA m, Monoid a) => V.RecExtend (Val (Input.Payload m a)) ->
  Input.Payload m a -> ConvertM m (ExpressionU m a)
convertExtend (V.RecExtend tag val rest) exprPl = do
  restS <- ConvertM.convertSubexpression rest
  (restRecord, hiddenEntities) <-
    case restS ^. rBody of
    BodyRecord r -> return (r, restS ^. rPayload . plData)
    _ -> do
      mAddField <- rest ^. V.payload . Input.mStored & Lens._Just %%~ makeAddField
      return
        ( Record [] (RecordExtending restS) mAddField
        , mempty
        )
  fieldS <-
    convertField
    (exprPl ^. Input.mStored) (rest ^? V.payload . plValI) restRecord
    (EntityId.ofRecExtendTag (exprPl ^. Input.entityId)) tag val
  restRecord
    & rItems %~ (fieldS:)
    & rMAddField . Lens._Just %~ (>>= setTagOrder (1 + length (restRecord ^. rItems)))
    & BodyRecord
    & addActions exprPl
    <&> rPayload . plData <>~ hiddenEntities
