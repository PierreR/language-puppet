{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedLists       #-}
module Helpers ( module Exports
               , compileCatalog
               , checkExprsSuccess
               , checkExprsError
               , getCatalog
               , getResource
               , getAttribute
               , spretty
               , withStdlibFunction
               ) where

import           Control.Monad            as Exports
import           Data.Monoid              as Exports
import           Data.Text                as Exports (Text)
import           Puppet.Interpreter.Pure  as Exports
import           Puppet.Interpreter.Types as Exports
import           Puppet.Parser.Types      as Exports
import           Puppet.PP                as Exports
import           Test.Hspec               as Exports

import           Control.Lens
import           Control.Monad.Except
import qualified Data.HashMap.Strict      as HM
import qualified Data.Maybe.Strict        as S
import           Data.Text                as Text
import qualified Data.Vector              as Vector

import           Puppet.Interpreter       (computeCatalog)
import           Puppet.Interpreter.Resolve
import           Puppet.Parser
import           Puppet.Stdlib

compileCatalog :: MonadError String m => Text -> m (FinalCatalog, EdgeMap, FinalCatalog, [Resource], InterpreterState)
compileCatalog input = do
    statements <- either (throwError . show) return (runPParser "dummy" input)
    let nodename = "node.fqdn"
        sttmap = [( (TopNode, nodename), NodeDeclaration (NodeDecl (NodeName nodename) statements S.Nothing (initialPPos "dummy")) ) ]
        (res, finalState, _) = pureEval dummyFacts sttmap (computeCatalog nodename)
    (catalog,em,exported,defResources) <- either (throwError . show) return res
    return (catalog,em,exported,defResources,finalState)

getCatalog :: MonadError String m => Text -> m FinalCatalog
getCatalog = fmap (view _1) . compileCatalog

spretty :: Pretty a => a -> String
spretty = flip displayS "" . renderCompact . pretty

getResource :: Monad m => RIdentifier -> FinalCatalog -> m Resource
getResource resid catalog = maybe (fail ("Unknown resource " ++ spretty resid)) return (HM.lookup resid catalog)

getAttribute :: Monad m => Text -> Resource -> m PValue
getAttribute att res = case res ^? rattributes . ix att of
                           Nothing -> fail ("Unknown attribute: " ++ Text.unpack att)
                           Just x -> return x

withStdlibFunction :: Text -> ( ([PValue] -> InterpreterMonad PValue) -> Spec ) -> Spec
withStdlibFunction fname testsuite =
    case stdlibFunctions ^? ix fname of
        Just f  -> testsuite f
        Nothing -> fail ("Don't know this function: " ++ show fname)

checkExprsSuccess :: Text ->  [Expression] -> Text -> Expectation
checkExprsSuccess fname args res =
  case evalExprs fname args of
    Left rr    -> expectationFailure (show rr)
    Right res' -> res' `shouldBe` res

checkExprsError :: Text ->  [Expression] -> String -> Expectation
checkExprsError fname args msg =
  case evalExprs fname args of
    Left rr -> show rr `shouldContain` msg
    Right r -> expectationFailure ("Should have errored, received this instead: " <> show r)

evalExprs :: Text -> [Expression] -> Either PrettyError Text
evalExprs fname =
  dummyEval . resolveValue . UFunctionCall fname . Vector.fromList
  >=> \pv -> case pv of
                PString s -> return s
                _ -> Left ("Expected a string, not " <> PrettyError (pretty pv))
