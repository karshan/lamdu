module Lamdu.Config.Default (defaultConfig) where

import Lamdu.Config (Config(..))
import qualified Graphics.DrawingCombinators as Draw
import qualified Graphics.UI.Bottle.EventMap as E

mk :: E.ModState -> E.Key -> E.ModKey
mk = E.ModKey

noMods :: E.Key -> E.ModKey
noMods = mk E.noMods

ctrl :: Char -> E.ModKey
ctrl = mk E.ctrl . E.charKey

alt :: Char -> E.ModKey
alt = mk E.alt . E.charKey

shift :: Char -> E.ModKey
shift = mk E.shift . E.charKey

ctrlAlt :: Char -> E.ModKey
ctrlAlt = mk (E.noMods {E.modCtrl = True, E.modAlt = True}) . E.charKey

k :: Char -> E.ModKey
k = noMods . E.charKey

defaultConfig :: Config
defaultConfig =
  Config
  { baseColor         = Draw.Color 1 1 1 1
  , baseTextSize      = 25
  , helpTextColor     = Draw.Color 1 1 1 1
  , helpTextSize      = 12
  , helpInputDocColor = Draw.Color 0.1 0.7 0.7 1
  , helpBGColor       = Draw.Color 0.2 0.15 0.1 0.5
  , quitKeys          = [ctrl 'q']
  , undoKeys          = [ctrl 'z']
  , redoKeys          = [ctrl 'y']
  , makeBranchKeys    = [ctrl 's']

  , jumpToBranchesKeys = [mk E.ctrl E.KeyF10]

  , overlayDocKeys    = [noMods E.KeyF1, alt 'h']

  , addNextParamKeys  = [noMods E.KeySpace]

  , delBranchKeys     = [alt 'o']

  , closePaneKeys     = [alt 'w']
  , movePaneDownKeys  = [mk E.alt E.KeyDown]
  , movePaneUpKeys    = [mk E.alt E.KeyUp]

  , replaceKeys       = [alt 'r']

  , pickResultKeys    = [noMods E.KeyEnter]
  , pickAndMoveToNextHoleKeys = [noMods E.KeySpace]

  , jumpToDefinitionKeys = [noMods E.KeyEnter]

  , delForwardKeys       = [noMods E.KeyDel, mk E.alt E.KeyDel]
  , delBackwardKeys      = [noMods E.KeyBackspace]
  , delKeys              = delForwardKeys defaultConfig ++ delBackwardKeys defaultConfig
  , wrapKeys             = [noMods E.KeySpace]
  , callWithArgumentKeys = [shift '9']
  , callWithNextArgumentKeys = [shift '0']
  , debugModeKeys = [ctrlAlt 'd', mk E.ctrl E.KeyF7]

  , newDefinitionKeys = [alt 'n']

  , definitionColor = Draw.Color 0.8 0.5 1 1
  , atomColor = definitionColor defaultConfig
  , parameterColor = Draw.Color 0.2 0.8 0.9 1
  , paramOriginColor = Draw.Color 1.0 0.8 0.5 1

  , literalIntColor = Draw.Color 0 1 0 1

  , previousCursorKeys = [mk E.alt E.KeyLeft]

  , holeResultCount = 8
  , holeResultScaleFactor = 0.75
  , holeSearchTermScaleFactor = 0.6
  , holeNumLabelScaleFactor = 0.3
  , holeNumLabelColor = Draw.Color 0.6 0.6 0.6 1

  , typeErrorHoleWrapBackgroundColor = Draw.Color 1.0 0 0 0.3
  , deletableHoleBackgroundColor = Draw.Color 0 1.0 0 0.1

  , activeHoleBackgroundColor   = Draw.Color 0.1 0.1 0.3 1
  , inactiveHoleBackgroundColor = Draw.Color 0.2 0.2 0.8 0.5

  , tagScaleFactor = 0.9

  , fieldTagScaleFactor = 0.8
  , fieldTint = Draw.Color 1 1 1 0.6

  , inferredValueScaleFactor = 0.7
  , inferredValueTint = Draw.Color 1 1 1 0.6

  , parenHighlightColor = Draw.Color 0.3 0 1 0.25

  , lambdaWrapKeys = [k '\\']
  , addWhereItemKeys = [k 'w']

  , lambdaColor = Draw.Color 1 0.2 0.2 1
  , lambdaTextSize = 30

  , rightArrowColor = Draw.Color 1 0.2 0.2 1
  , rightArrowTextSize = 30

  , whereColor = Draw.Color 0.8 0.6 0.1 1
  , whereScaleFactor = 0.85
  , whereLabelScaleFactor = whereScaleFactor defaultConfig

  , typeScaleFactor = 0.6
  , squareParensScaleFactor = 0.96

  , foreignModuleColor = Draw.Color 1 0.3 0.35 1
  , foreignVarColor = Draw.Color 1 0.65 0.25 1

  , cutKeys = [ctrl 'x', k 'x']
  , pasteKeys = [ctrl 'v', k 'v']

  , inactiveTintColor = Draw.Color 1 1 1 0.8
  , activeDefBGColor = Draw.Color 0.04 0.04 0.04 1

  , inferredTypeTint = inferredValueTint defaultConfig
  , inferredTypeErrorBGColor = Draw.Color 0.5 0.05 0.05 1
  , inferredTypeBGColor = Draw.Color 0.05 0.15 0.2 1

  -- For definitions
  , collapsedForegroundColor = Draw.Color 1 0.4 0.3 1
  -- For parameters
  , collapsedCompactBGColor = Draw.Color 0.1 0.2 0.25 1
  , collapsedExpandedBGColor = Draw.Color 0.18 0.14 0.05 1
  , collapsedExpandKeys = [noMods E.KeyEnter]
  , collapsedCollapseKeys = [noMods E.KeyEsc]

  , monomorphicDefOriginForegroundColor = paramOriginColor defaultConfig
  , polymorphicDefOriginForegroundColor = collapsedForegroundColor defaultConfig

  , builtinOriginNameColor = monomorphicDefOriginForegroundColor defaultConfig

  , cursorBGColor = Draw.Color 0 0 1 0.45

  , listBracketTextSize = 25
  , listBracketColor = Draw.Color 0.8 0.8 0.9 1
  , listCommaTextSize = listBracketTextSize defaultConfig
  , listCommaColor = listBracketColor defaultConfig

  , listAddItemKeys = [k ',']

  , selectedBranchColor = Draw.Color 0 0.5 0 1

  , jumpLHStoRHSKeys = [k '`']
  , jumpRHStoLHSKeys = [k '`']

  , shrinkBaseFontKeys = [ctrl '-']
  , enlargeBaseFontKeys = [ctrl '=']

  , enlargeFactor = 1.1
  , shrinkFactor = 1.1

  , defTypeLabelTextSize = 16
  , defTypeLabelColor = Draw.Color 0.6 0.7 1 1

  , defTypeBoxScaleFactor = 0.6

  , acceptInferredTypeKeys = [noMods E.KeySpace, noMods E.KeyEnter]

  , autoGeneratedNameTint = Draw.Color 0.9 0.8 0.7 1
  , collisionSuffixTint = Draw.Color 1 1 1 1
  , collisionSuffixBGColor = Draw.Color 0.7 0 0 1
  , collisionSuffixScaleFactor = 0.5

  , paramDefSuffixScaleFactor = 0.4

  , enterSubexpressionKeys = [mk E.shift E.KeyRight]
  , leaveSubexpressionKeys = [mk E.shift E.KeyLeft]

  , replaceInferredValueKeys = noMods E.KeyEnter : delKeys defaultConfig
  , keepInferredValueKeys = [noMods E.KeyEsc]
  , acceptInferredValueKeys = [noMods E.KeySpace]

  , nextInfoModeKeys = [noMods E.KeyF7]

  , operatorChars = "\\+-*/^=><&|%$:."
  , alphaNumericChars = ['a'..'z'] ++ ['0'..'9']

  , recordTypeParensColor = rightArrowColor defaultConfig
  , recordValParensColor = Draw.Color 0.2 1 0.2 1
  , recordAddFieldKeys = [k 'a', k ',']

  , presentationChoiceScaleFactor = 0.4
  , presentationChoiceColor = Draw.Color 0.4 0.4 0.4 1

  , labeledApplyBGColor = Draw.Color 1 1 1 0.07
  }
