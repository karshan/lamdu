{-# LANGUAGE TemplateHaskell #-}
module Lamdu.Sugar.AddNames.NameGen
  ( NameGen, initial
  , IsFunction(..), existingName, newName
  ) where

import Control.Applicative ((<$>))
import Control.Arrow ((&&&))
import Control.Lens.Operators
import Control.Monad.Trans.State (State, state)
import Data.Map (Map)
import Data.Maybe (fromMaybe)
import qualified Control.Lens as Lens
import qualified Data.Map as Map

data IsFunction = Function | NotFunction

data NameGen g = NameGen
  { _ngUnusedNames :: [String]
  , _ngUnusedFuncNames :: [String]
  , _ngUsedNames :: Map g String
  }
Lens.makeLenses ''NameGen

initial :: Ord g => NameGen g
initial =
  NameGen indepNames indepFuncNames Map.empty
  where
    indepFuncNames = numberCycle ["f", "g", "h"]
    indepNames = numberCycle ["x", "y", "z", "w", "u", "v"]
    numberCycle s = (s ++) . concat . zipWith appendAll [0::Int ..] $ repeat s
    appendAll num = map (++ show num)

existingName :: (Ord g, Show g) => g -> State (NameGen g) String
existingName g =
  fromMaybe ("TodoError:" ++ show g) <$>
  Lens.uses ngUsedNames (Map.lookup g)

newName :: Ord g => (String -> Bool) -> IsFunction -> g -> State (NameGen g) String
newName acceptName isFunc g = do
  let
    loop = do
      name <- state (head &&& tail)
      if acceptName name
        then return name
        else loop
  name <- Lens.zoom names loop
  ngUsedNames %= Map.insert g name
  return name
  where
    names =
      case isFunc of
      NotFunction -> ngUnusedNames
      Function -> ngUnusedFuncNames
