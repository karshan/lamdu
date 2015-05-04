module Lamdu.Eval.Background
  ( Evaluator
  , start
  , stop
  , get
  ) where

data Evaluator pl = Evaluator
  { invalidateCache :: IO ()
  , curState :: IORef (State pl)
  ,
  }

start :: IO () -> Val pl -> IO (Evaluator pl)
start invalidateCache val =

stop :: Evaluator -> IO ()

data ComputedVal pl
  = NotYet
  | ComputedVal (ValBody (ComputedVal pl) pl)

data State pl = State
  { scopeMap :: Map ScopeId (pl, ScopeId)
  , valMap :: Map (ScopeId, pl) (ComputedVal pl)
  }

get :: Evaluator pl -> IO (State pl)
