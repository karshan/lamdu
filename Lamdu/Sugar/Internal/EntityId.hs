{-# LANGUAGE GeneralizedNewtypeDeriving #-}
module Lamdu.Sugar.Internal.EntityId
    ( EntityId
    , bs
    , ofValI, ofIRef
    , ofLambdaParam
    , ofLambdaTagParam
    , ofGetFieldTag
    , ofRecExtendTag
    , randomizeExprAndParams
    ) where

import Data.ByteString (ByteString)
import Data.Hashable (Hashable)
import Data.Store.Guid (Guid)
import Data.Store.IRef (IRef)
import Lamdu.Expr.Val (Val)
import System.Random (RandomGen)
import qualified Data.Store.Guid as Guid
import qualified Lamdu.Expr.GenIds as GenIds
import qualified Lamdu.Expr.IRef as ExprIRef
import qualified Lamdu.Expr.Type as T
import qualified Lamdu.Expr.UniqueId as UniqueId
import qualified Lamdu.Expr.Val as V

newtype EntityId = EntityId Guid
    deriving (Eq, Hashable, Show)

bs :: EntityId -> ByteString
bs (EntityId guid) = Guid.bs guid

randomizeExprAndParams ::
    RandomGen gen =>
    gen -> Val (EntityId -> a) -> Val a
randomizeExprAndParams gen =
    GenIds.randomizeExprAndParams gen . fmap addEntityId
    where
        addEntityId f guid = f (EntityId guid)

augment :: String -> EntityId -> EntityId
augment str (EntityId x) = EntityId $ Guid.augment str x

ofIRef :: IRef m a -> EntityId
ofIRef = EntityId . UniqueId.toGuid

ofValI :: ExprIRef.ValI m -> EntityId
ofValI = ofIRef . ExprIRef.unValI

ofLambdaParam :: V.Var -> EntityId
ofLambdaParam = EntityId . UniqueId.toGuid

ofLambdaTagParam :: V.Var -> T.Tag -> EntityId
ofLambdaTagParam v p =
    EntityId $ Guid.combine (UniqueId.toGuid v) (UniqueId.toGuid p)

ofGetFieldTag :: EntityId -> EntityId
ofGetFieldTag = augment "tag"

ofRecExtendTag :: EntityId -> EntityId
ofRecExtendTag = augment "tag"
