{-# LANGUAGE LambdaCase #-}
{-|

Horrible and hackish ... but damn useful. This can be used as a standalone
executable or a ghci script for interactive usage. It comes with a sample Puppet
site (that I hope will gets more realistic later).

When given a single argument, it will try to parse the given file, and will
print the parsed values :

> $ puppetresources samplesite/manifests/site.pp
> node test.nod {
>     apt::builddep { Interpolable [Literal "glusterfs-server"]:
>     ;
>     }
>     ...

With two arguments, it will try to compute the catalog for a given node. The
first argument must be the path to the Puppet directory and the second the
name of the node. Note that regexp node names do not work yet.

> $ puppetresources samplesite test.nod
> The defined() function is not implemented for resource references. Returning true at "samplesite/modules/apt/manifests/ppa.pp" (line 20, column 3)
> The defined() function is not implemented for resource references. Returning true at "samplesite/modules/apt/manifests/key.pp" (line 38, column 7)
> The defined() function is not implemented for resource references. Returning true at "samplesite/modules/apt/manifests/key.pp" (line 42, column 7)
> anchor {
>     "apt::builddep::glusterfs-server": #"samplesite/modules/apt/manifests/builddep.pp" (line 12, column 12)
>         name => "apt::builddep::glusterfs-server";
>     "apt::key/Add key: 55BE302B from Apt::Source debian_unstable": #"samplesite/modules/apt/manifests/key.pp" (line 32, column 16)
>         name => "apt::key/Add key: 55BE302B from Apt::Source debian_unstable";
> ...

When adding a file name as the third argument to the previous invocation, it
will display the value of the /content/ attribute of the named /file/ resource.

> $ puppetresources samplesite test.nod karmic.pref
> The defined() function is not implemented for resource references. Returning true at "samplesite/modules/apt/manifests/ppa.pp" (line 20, column 3)
> The defined() function is not implemented for resource references. Returning true at "samplesite/modules/apt/manifests/key.pp" (line 38, column 7)
> The defined() function is not implemented for resource references. Returning true at "samplesite/modules/apt/manifests/key.pp" (line 42, column 7)
> # karmic
> Package: *
> Pin: release a=karmic
> Pin-Priority: 700

You can also just use a resource name :

> $ puppetresources samplesite test.nod 'exec[apt_update]'
> exec {
>   "apt_update": #"samplesite/modules/apt/manifests/update.pp" (line 4, column 10)
>       command     => "/usr/bin/apt-get update",
>       logoutput   => "false",
>       refreshonly => "true",
>       returns     => 0,
>       timeout     => 300,
>       tries       => 1,
>       try_sleep   => 0;
> }

With GHCI there are tons of things you can do. First initialize it

>>> queryfunc <- initializedaemon "./samplesite/"

You can now compute catalogs for various nodes.

>>> c1 <- queryfunc "test.nod"
The defined() function is not implemented for resource references. Returning true at "./samplesite//modules/apt/manifests/ppa.pp" (line 20, column 3)
The defined() function is not implemented for resource references. Returning true at "./samplesite//modules/apt/manifests/key.pp" (line 38, column 7)
The defined() function is not implemented for resource references. Returning true at "./samplesite//modules/apt/manifests/key.pp" (line 42, column 7)
>>> c2 <- queryfunc "test2.nod"
The defined() function is not implemented for resource references. Returning true at "./samplesite//modules/apt/manifests/ppa.pp" (line 20, column 3)
The defined() function is not implemented for resource references. Returning true at "./samplesite//modules/apt/manifests/key.pp" (line 38, column 7)
The defined() function is not implemented for resource references. Returning true at "./samplesite//modules/apt/manifests/key.pp" (line 42, column 7)

And you can check what the difference is between catalogs.

>>> diff c1 c2
file[karmic-updates.pref] {
# content
    + Pin-Priority: 750
    - Pin-Priority: 700
}

You also can manipulate catalogs.

>>> Map.size c1
25
>>> mapM_ print $ Map.toList $ Map.map (length . lines . (\x -> case x of (PString n) -> n) .fromJust . Map.lookup "content" . rrattributes) $ Map.filter (Map.member "content" . rrattributes) c1
(("file","debian_unstable.list"),3)
(("file","debian_unstable.pref"),4)
(("file","karmic-security.pref"),4)
(("file","karmic-updates.pref"),4)
(("file","karmic.pref"),4)

A typical usage of this tool is to compute a reference catalog, and then check the differences as you alter it. This can be done this way :

>>> reference <- queryfunc "test.nod"

And then run the following command every time you need to verify your changes are correct :

>>> queryfunc "test.nod" >>= diff reference

-}
module Main where

import System.IO
import qualified Data.HashMap.Strict as HM
import qualified System.Log.Logger as LOG
import qualified Data.ByteString.Lazy.Char8 as BSL
import qualified Data.Text as T
import qualified Data.Text.IO as T
import Data.Monoid hiding (First)
import qualified Text.Parsec as P
import qualified Data.Vector as V
import qualified Data.Either.Strict as S
import Options.Applicative as O hiding ((&))
import Control.Monad
import Text.Regex.PCRE.String
import Data.Text.Strict.Lens
import Data.Aeson (encode)
import Data.Yaml (decodeFileEither)
import Control.Lens as L

import Facter

import Puppet.PP hiding ((<$>))
import Puppet.Preferences
import Puppet.Daemon
import Puppet.Interpreter.Types
import Puppet.Parser.Types
import Puppet.Parser
import Puppet.Parser.PrettyPrinter()
import Puppet.Interpreter.PrettyPrinter()
import PuppetDB.Remote
import PuppetDB.Dummy
import PuppetDB.TestDB
import PuppetDB.Common
import Puppet.Testing hiding ((<$>))
import Puppet.Lens

import Control.Concurrent.ParallelIO (parallel_)
import Data.Maybe (mapMaybe)

tshow :: Show a => a -> T.Text
tshow = T.pack . show

type QueryFunc = T.Text -> IO (S.Either Doc (FinalCatalog, EdgeMap, FinalCatalog))

checkErrorStrict :: S.Either Doc x -> IO x
checkErrorStrict (S.Left rr) = putDoc rr >> putStrLn "" >> error "error!"
checkErrorStrict (S.Right x) = return x

{-| Does all the work of initializing a daemon for querying.
Returns the final catalog when given a node name. Note that this is pretty
hackish as it will generate facts from the local computer !
-}

initializedaemonWithPuppet :: LOG.Priority -> PuppetDBAPI -> FilePath -> Maybe FilePath -> (Facts -> Facts) -> IO QueryFunc
initializedaemonWithPuppet prio pdbapi puppetdir hierapath overrideFacts = do
    LOG.updateGlobalLogger "Puppet.Daemon" (LOG.setLevel prio)
    q <- fmap ((prefPDB .~ pdbapi) . (hieraPath .~ hierapath)) (genPreferences puppetdir) >>= initDaemon
    let f ndename = fmap overrideFacts (puppetDBFacts ndename pdbapi)
            >>= _dGetCatalog q ndename
    return f

parseFile :: FilePath -> IO (Either P.ParseError (V.Vector Statement))
parseFile fp = T.readFile fp >>= P.runParserT puppetParser () fp

printContent :: T.Text -> FinalCatalog -> IO ()
printContent filename catalog =
        case HM.lookup (RIdentifier "file" filename) catalog of
            Nothing -> error "File not found"
            Just r  -> case HM.lookup "content" (_rattributes r) of
                           Nothing -> error "This file has no content"
                           Just (PString c)  -> T.putStrLn c
                           Just x -> print x

data CommandLine = CommandLine { _pdb          :: Maybe String
                               , _showjson     :: Bool
                               , _showContent  :: Bool
                               , _resourceType :: Maybe T.Text
                               , _resourceName :: Maybe T.Text
                               , _puppetdir    :: FilePath
                               , _nodename     :: Maybe String
                               , _pdbfile      :: Maybe FilePath
                               , _loglevel     :: LOG.Priority
                               , _hieraFile    :: Maybe FilePath
                               , _factsFile    :: Maybe FilePath
                               , _factsDef     :: Maybe FilePath
                               } deriving Show

prepareForPuppetApply :: WireCatalog -> WireCatalog
prepareForPuppetApply w =
    let res = V.filter (\r -> r ^. rvirtuality == Normal) (w ^. wResources) :: V.Vector Resource
        -- step 1 : capitalize resources types (and names in case of
        -- classes), and filter out exported stuff
        capi :: RIdentifier -> RIdentifier
        capi r = r & itype %~ capitalizeRT & if r ^. itype == "class"
                                                then iname %~ capitalizeRT
                                                else id
        aliasMap :: HM.HashMap RIdentifier T.Text
        aliasMap = HM.fromList $ concatMap genAliasList (res ^.. folded)
        genAliasList r = map (\n -> (RIdentifier (r ^. rid . itype) n, r ^. rid . iname)) (r ^. rid . iname : r ^.. ralias . folded)
        nr = V.map (rid %~ capi) res
        ne = V.map capEdge (w ^. wEdges)
        capEdge (PuppetEdge a b x) = PuppetEdge (capi a) (capi b) x
        -- step 2 : replace all references with the resource title in case
        -- of aliases - yes this sucks
        knownEdge :: PuppetEdge -> Bool
        knownEdge (PuppetEdge s d _) = (aliasMap ^. contains s) && (aliasMap ^. contains d)
        correctEdges = V.map correctEdge $ V.filter knownEdge ne
        correctResources = V.map correctResource nr
        correct :: RIdentifier -> RIdentifier
        correct ri = ri & iname %~ \n -> HM.lookupDefault n ri aliasMap
        correctEdge :: PuppetEdge -> PuppetEdge
        correctEdge (PuppetEdge s d x) = PuppetEdge (correct s) (correct d) x
        correctResource :: Resource -> Resource
        correctResource r = r & rrelations %~ HM.fromList . filter (\(x,_) -> aliasMap ^. contains x) . map (_1 %~ correct) . HM.toList
    in   (wResources .~ correctResources)
       . (wEdges     .~ correctEdges)
       $ w

cmdlineParser :: Parser CommandLine
cmdlineParser = CommandLine <$> optional remotepdb
                            <*> sj
                            <*> sc
                            <*> optional (T.pack <$> rt)
                            <*> optional (T.pack <$> rn)
                            <*> pdir
                            <*> optional nn
                            <*> optional pdbfile
                            <*> priority
                            <*> optional hiera
                            <*> optional fcts
                            <*> optional fco
    where
        sc = switch (  long "showcontent"
                    <> short 'c'
                    <> help "When specifying a file resource, only output its content (useful for testing templates)")
        sj = switch (  long "JSON"
                    <> short 'j'
                    <> help "Shows the output as a JSON document (useful for full catalog views)")
        remotepdb = strOption (  long "pdburl"
                              <> help "URL of the puppetdb (ie. http://localhost:8080/).")
        rt = strOption (  long "type"
                       <> short 't'
                       <> help "Filter the output by resource type (accepts a regular expression, ie '^file$')")
        rn = strOption (  long "name"
                       <> short 'n'
                       <> help "Filter the output by resource name (accepts a regular expression)")
        pdir = strOption (  long "puppetdir"
                         <> short 'p'
                         <> help "Puppet directory")
        nn   = strOption (  long "node"
                         <> short 'o'
                         <> help "Node name. Using 'allnodes' enables a special mode where all nodes present in site.pp are tried. Run with +RTS -N")
        pdbfile = strOption (  long "pdbfile"
                            <> help "Path to the testing PuppetDB file.")
        hiera = strOption (  long "hiera"
                          <> help "Path to the Hiera configuration file (default hiera.yaml)"
                          <> value "hiera.yaml"
                          )
        priority = option (  long "loglevel"
                          <> short 'v'
                          <> help "Values are : DEBUG, INFO, NOTICE, WARNING, ERROR, CRITICAL, ALERT, EMERGENCY"
                          <> value LOG.WARNING
                          )
        fcts = strOption (  long "facts-override"
                         <> help "Path to a Yaml file containing a list of 'facts' that will override locally resolved facts"
                         )
        fco = strOption  (  long "facts-defaults"
                         <> help "Path to a Yaml file containing a list of 'facts' that will be used as defaults"
                         )

loadFactsOverrides :: FilePath -> IO Facts
loadFactsOverrides fp = decodeFileEither fp >>= \case
    Left rr -> error ("Error when parsing " ++ fp ++ ": " ++ show rr)
    Right x -> case traverse tv x of
                   Just y -> return y
                   Nothing -> error ("Error when parsing " ++ fp ++ ": some of the values were not strings")
    where
        tv x = x ^? _PString <|> isBool x
        isBool (PBoolean True)  = Just "true"
        isBool (PBoolean False) = Just "false"
        isBool _ = Nothing

run :: CommandLine -> IO ()
run (CommandLine _ _ _ _ _ f Nothing _ _ _ _ _) = parseFile f >>= \case
            Left rr -> error ("parse error:" ++ show rr)
            Right s -> putDoc (vcat (map pretty (V.toList s)))
run c@(CommandLine puppeturl _ _ _ _ puppetdir (Just ndename) mpdbf prio hpath fcts fdef) = do
    let checkError r (S.Left rr) = error (show (red r <> ":" <+> rr))
        checkError _ (S.Right x) = return x
        tnodename = T.pack ndename
    pdbapi <- case (puppeturl, mpdbf) of
                  (Nothing, Nothing) -> return dummyPuppetDB
                  (Just _, Just _)   -> error "You must choose between a testing PuppetDB and a remote one"
                  (Just url, _)      -> pdbConnect (T.pack url) >>= checkError "Error when connecting to the remote PuppetDB"
                  (_, Just file)     -> loadTestDB file >>= checkError "Error when initializing the PuppetDB API"
    !factsOverrides <- case (fcts, fdef) of
                           (Just _, Just _) -> error "You can't use --facts-override and --facts-defaults at the same time"
                           (Just p, Nothing) -> HM.union `fmap` loadFactsOverrides p
                           (Nothing, Just p) -> (flip HM.union) `fmap` loadFactsOverrides p
                           (Nothing, Nothing) -> return id
    queryfunc <- initializedaemonWithPuppet prio pdbapi puppetdir hpath factsOverrides
    printFunc <- hIsTerminalDevice stdout >>= \isterm -> return $ \x ->
        if isterm
            then putDoc x >> putStrLn ""
            else displayIO stdout (renderCompact x) >> putStrLn ""
    if tnodename == "allnodes"
        then do
            allstmts <- parseFile (puppetdir <> "/manifests/site.pp") >>= \presult -> case presult of
                                                                                          Left rr -> error (show rr)
                                                                                          Right x -> return x
            let topnodes = mapMaybe getNodeName (V.toList allstmts)
                getNodeName (Node (NodeName n) _ _ _) = Just n
                getNodeName _ = Nothing
            parallel_ (map (computeCatalogs True queryfunc pdbapi printFunc c) topnodes)
            putStrLn ("Tested " ++ show (length topnodes) ++ " nodes.")
        else computeCatalogs False queryfunc pdbapi printFunc c tnodename
    void $ commitDB pdbapi

computeCatalogs :: Bool -> QueryFunc -> PuppetDBAPI -> (Doc -> IO ()) -> CommandLine -> T.Text -> IO ()
computeCatalogs testOnly queryfunc pdbapi printFunc (CommandLine _ showjson showcontent mrt mrn puppetdir _ _ _ _ _ _) tnodename = queryfunc tnodename >>= \case
    S.Left rr -> if testOnly
                     then putDoc ("Problem with" <+> ttext tnodename <+> ":" <+> rr </> mempty)
                     else putDoc rr >> putStrLn "" >> error "error!"
    S.Right (rawcatalog,m,rawexported) -> do
        let wireCatalog = generateWireCatalog tnodename (rawcatalog <> rawexported) m
        void $ replaceCatalog pdbapi wireCatalog
        let cmpMatch Nothing _ curcat = return curcat
            cmpMatch (Just rg) lns curcat = compile compBlank execBlank (T.unpack rg) >>= \case
                Left rr -> error ("Error compiling regexp 're': "  ++ show rr)
                Right rec -> fmap HM.fromList $ filterM (filterResource lns rec) (HM.toList curcat)
            filterResource lns rec v = execute rec (v ^. lns) >>= \case
                                            Left rr -> error ("Error when applying regexp: " ++ show rr)
                                            Right Nothing -> return False
                                            _ -> return True
            filterCatalog = cmpMatch mrt (_1 . itype . unpacked) >=> cmpMatch mrn (_1 . iname . unpacked)
        case (testOnly, showcontent, showjson) of
            (True, _, _) -> void $ testCatalog tnodename puppetdir rawcatalog basicTest
            (_, _, True) -> BSL.putStrLn (encode (prepareForPuppetApply wireCatalog))
            (_, True, _) -> do
                catalog  <- filterCatalog rawcatalog
                unless (mrt == Just "file" || mrt == Nothing) (error $ "Show content only works for file, not for " ++ show mrt)
                case mrn of
                    Just f -> printContent f catalog
                    Nothing -> error "You should supply a resource name when using showcontent"
            _ -> do
                catalog  <- filterCatalog rawcatalog
                exported <- filterCatalog rawexported
                void $ testCatalog tnodename puppetdir rawcatalog basicTest
                printFunc (pretty (HM.elems catalog))
                unless (HM.null exported) $ do
                    printFunc (mempty <+> dullyellow "Exported:" <+> mempty)
                    printFunc (pretty (HM.elems exported))

main :: IO ()
main = execParser pinfo >>= run
    where
        pinfo :: ParserInfo CommandLine
        pinfo = ParserInfo (helper <*> cmdlineParser) True "A useful program for parsing puppet files, generating and inspecting catalogs" "puppetresources - a useful utility for dealing with Puppet" "" 3
