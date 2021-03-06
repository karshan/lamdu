{-# LANGUAGE RankNTypes, NoMonomorphismRestriction, FlexibleContexts #-}
module Lamdu.Expr.Lens
  -- ValLeaf prisms:
  ( _LGlobal
  , _LHole
  , _LRecEmpty
  , _LVar
  , _LLiteralInteger
  -- ValBody prisms:
  , _BLeaf
  , _BApp
  , _BAbs
  , _BGetField
  , _BRecExtend
  -- Leafs
  , valGlobal        , valBodyGlobal
  , valHole          , valBodyHole
  , valVar           , valBodyVar
  , valRecEmpty      , valBodyRecEmpty
  , valLiteralInteger, valBodyLiteralInteger
  -- Non-leafs
  , valGetField
  , valApply
  -- Pure vals:
  , pureValBody
  , pureValApply
  -- Types:
  , _TRecord
  , _TFun
  -- Tags:
  , valTags, bodyTags, biTraverseBodyTags
  -- Composites:
  , compositeTags
  -- Subexpressions:
  , subExprPayloads
  , subExprs
  , payloadsIndexedByPath
  ) where

import Control.Applicative (Applicative(..), (<$>))
import Control.Lens (Traversal', Prism', prism', Iso', iso)
import Control.Lens.Operators
import Control.Monad (void)
import Lamdu.Expr.Type (Type)
import Lamdu.Expr.Val (Val(..))
import qualified Control.Lens as Lens
import qualified Lamdu.Expr.Type as T
import qualified Lamdu.Expr.Val as V

valApply :: Traversal' (Val a) (V.Apply (Val a))
valApply = V.body . _BApp

pureValBody :: Iso' (Val ()) (V.Body (Val ()))
pureValBody = iso V._valBody (Val ())

pureValApply :: Prism' (Val ()) (V.Apply (Val ()))
pureValApply = pureValBody . _BApp

valGlobal :: Traversal' (Val a) V.GlobalId
valGlobal = V.body . valBodyGlobal

valHole :: Traversal' (Val a) ()
valHole = V.body . valBodyHole

valVar :: Traversal' (Val a) V.Var
valVar = V.body . valBodyVar

valRecEmpty :: Traversal' (Val a) ()
valRecEmpty = V.body . valBodyRecEmpty

valLiteralInteger :: Traversal' (Val a) Integer
valLiteralInteger = V.body . valBodyLiteralInteger

valGetField  :: Traversal' (Val a) (V.GetField (Val a))
valGetField = V.body . _BGetField

_LGlobal :: Prism' V.Leaf V.GlobalId
_LGlobal = prism' V.LGlobal get
  where
    get (V.LGlobal gid) = Just gid
    get _ = Nothing

_LHole :: Prism' V.Leaf ()
_LHole = prism' (\() -> V.LHole) get
  where
    get V.LHole = Just ()
    get _ = Nothing

_LRecEmpty :: Prism' V.Leaf ()
_LRecEmpty = prism' (\() -> V.LRecEmpty) get
  where
    get V.LRecEmpty = Just ()
    get _ = Nothing

_LVar :: Prism' V.Leaf V.Var
_LVar = prism' V.LVar get
  where
    get (V.LVar gid) = Just gid
    get _ = Nothing

_LLiteralInteger :: Prism' V.Leaf Integer
_LLiteralInteger = prism' V.LLiteralInteger get
  where
    get (V.LLiteralInteger i) = Just i
    get _ = Nothing

-- TODO: _V* -> _B*
_BLeaf :: Prism' (V.Body a) V.Leaf
_BLeaf = prism' V.BLeaf get
  where
    get (V.BLeaf x) = Just x
    get _ = Nothing

_BApp :: Prism' (V.Body a) (V.Apply a)
_BApp = prism' V.BApp get
  where
    get (V.BApp x) = Just x
    get _ = Nothing

_BAbs :: Prism' (V.Body a) (V.Lam a)
_BAbs = prism' V.BAbs get
  where
    get (V.BAbs x) = Just x
    get _ = Nothing

_BGetField :: Prism' (V.Body a) (V.GetField a)
_BGetField = prism' V.BGetField get
  where
    get (V.BGetField x) = Just x
    get _ = Nothing

_BRecExtend :: Prism' (V.Body a) (V.RecExtend a)
_BRecExtend = prism' V.BRecExtend get
  where
    get (V.BRecExtend x) = Just x
    get _ = Nothing

valBodyGlobal :: Prism' (V.Body e) V.GlobalId
valBodyGlobal = _BLeaf . _LGlobal

valBodyHole :: Prism' (V.Body expr) ()
valBodyHole = _BLeaf . _LHole

valBodyVar :: Prism' (V.Body expr) V.Var
valBodyVar = _BLeaf . _LVar

valBodyRecEmpty :: Prism' (V.Body expr) ()
valBodyRecEmpty = _BLeaf . _LRecEmpty

valBodyLiteralInteger :: Prism' (V.Body expr) Integer
valBodyLiteralInteger = _BLeaf . _LLiteralInteger

_TRecord :: Prism' Type (T.Composite T.Product)
_TRecord = prism' T.TRecord get
  where
    get (T.TRecord x) = Just x
    get _ = Nothing

_TFun :: Prism' Type (Type, Type)
_TFun = prism' (uncurry T.TFun) get
  where
    get (T.TFun arg res) = Just (arg, res)
    get _ = Nothing

compositeTags :: Traversal' (T.Composite p) T.Tag
compositeTags f (T.CExtend tag typ rest) =
  mkCExtend <$> f tag <*> compositeTags f rest
  where
    mkCExtend tag' = T.CExtend tag' typ
compositeTags _ r = pure r

subExprPayloads :: Lens.IndexedTraversal (Val ()) (Val a) (Val b) a b
subExprPayloads f val@(Val pl body) =
  Val
  <$> Lens.indexed f (void val) pl
  <*> (body & Lens.traversed .> subExprPayloads %%~ f)

subExprs :: Lens.Fold (Val a) (Val a)
subExprs =
  Lens.folding f
  where
    f x = x : x ^.. V.body . Lens.traversed . subExprs

payloadsIndexedByPath ::
  Lens.IndexedTraversal
  [Val ()]
  (Val a)
  (Val b)
  a b
payloadsIndexedByPath f =
  go []
  where
    go path val@(Val pl body) =
      Val
      <$> Lens.indexed f newPath pl
      <*> Lens.traversed (go newPath) body
      where
        newPath = void val : path

biTraverseBodyTags ::
  Applicative f =>
  (T.Tag -> f T.Tag) -> (a -> f b) ->
  V.Body a -> f (V.Body b)
biTraverseBodyTags onTag onChild body =
  case body of
  V.BGetField (V.GetField r t) ->
    V.BGetField <$> (V.GetField <$> onChild r <*> onTag t)
  V.BRecExtend (V.RecExtend t v r) ->
    V.BRecExtend <$> (V.RecExtend <$> onTag t <*> onChild v <*> onChild r)
  _ -> Lens.traverse onChild body

bodyTags :: Lens.Traversal' (V.Body a) T.Tag
bodyTags f = biTraverseBodyTags f pure

valTags :: Lens.Traversal' (Val a) T.Tag
valTags f = V.body $ biTraverseBodyTags f (valTags f)
