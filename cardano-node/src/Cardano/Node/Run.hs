{-# LANGUAGE BangPatterns        #-}
{-# LANGUAGE CPP                 #-}
{-# LANGUAGE DataKinds           #-}
{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE GADTs               #-}
{-# LANGUAGE NamedFieldPuns      #-}
{-# LANGUAGE PackageImports      #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

#if !defined(mingw32_HOST_OS)
#define UNIX
#endif

module Cardano.Node.Run
  ( runNode
  , checkVRFFilePermissions
  ) where

import           Cardano.Prelude hiding (ByteString, atomically, take, trace, STM)
import           Prelude (String, id)
import           Data.IP (toSockAddr)

import qualified Control.Concurrent.Async as Async
import           Control.Monad.Trans.Except.Extra (left)
import           Control.Monad.Class.MonadSTM.Strict
import           "contra-tracer" Control.Tracer
import qualified Data.Map.Strict as Map
import           Data.Text (breakOn, pack, take)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import           Data.Time.Clock (UTCTime, getCurrentTime)
import           Data.Time.Clock.POSIX (utcTimeToPOSIXSeconds)
import           Data.Version (showVersion)
import           Network.HostName (getHostName)
import           Network.Socket (AddrInfo, Socket)
import           System.Directory (canonicalizePath, createDirectoryIfMissing,
                     makeAbsolute)
import           System.Environment (lookupEnv)
import qualified System.Remote.Monitoring as EKG

#ifdef UNIX
import           System.Posix.Files
import           System.Posix.Types (FileMode)
import qualified System.Posix.Signals as Signals
#else
import           System.Win32.File
#endif

import           Cardano.BM.Data.LogItem (LogObject (..))
import           Cardano.BM.Data.Tracer (ToLogObject (..), TracingVerbosity (..))
import           Cardano.BM.Data.Transformers (setHostname)
import           Cardano.BM.Trace
import           Paths_cardano_node (version)

import qualified Cardano.Crypto.Libsodium as Crypto

import qualified Cardano.Logging as NL
import           Cardano.Node.Configuration.Logging (EKGDirect (..),
                     LoggingLayer (..), Severity (..), createLoggingLayer,
                     nodeBasicInfo, shutdownLoggingLayer)
import           Cardano.Node.Configuration.POM (NodeConfiguration (..),
                     PartialNodeConfiguration (..), SomeNetworkP2PMode (..),
                     defaultPartialNodeConfiguration, makeNodeConfiguration,
                     ncProtocol, parseNodeConfigurationFP)
import           Cardano.Node.Queries (HasKESInfo (..), HasKESMetricsData (..))
import           Cardano.Node.Types
import           Cardano.TraceDispatcher.BasicInfo.Combinators (getBasicInfo)
import           Cardano.TraceDispatcher.BasicInfo.Types
import           Cardano.TraceDispatcher.Era.Byron ()
import           Cardano.TraceDispatcher.Era.Shelley ()
import           Cardano.TraceDispatcher.Tracers (mkDispatchTracers)
import           Cardano.Tracing.Config (TraceOptions (..), TraceSelection (..))
import           Cardano.Tracing.Constraints (TraceConstraints)
import           Cardano.Tracing.Startup

import qualified Ouroboros.Consensus.BlockchainTime.WallClock.Types as WCT
import           Ouroboros.Consensus.Cardano.Block
import           Ouroboros.Consensus.Cardano.CanHardFork
import qualified Ouroboros.Consensus.Config as Consensus
import           Ouroboros.Consensus.Config.SupportsNode
                     (ConfigSupportsNode (..))
import           Ouroboros.Consensus.HardFork.Combinator.Degenerate
import           Ouroboros.Consensus.Node (RunNode, RunNodeArgs (..),
                     StdRunNodeArgs (..), NetworkP2PMode (..))
import qualified Ouroboros.Consensus.Node as Node (getChainDB, run)
import           Ouroboros.Consensus.Node.ProtocolInfo
import           Ouroboros.Consensus.Node.NetworkProtocolVersion
import           Ouroboros.Consensus.Shelley.Ledger.Ledger
import           Ouroboros.Consensus.Util.Orphans ()
import           Ouroboros.Network.Subscription
                   ( DnsSubscriptionTarget (..)
                   , IPSubscriptionTarget (..)
                   )
import qualified Ouroboros.Network.Diffusion as Diffusion
import qualified Ouroboros.Network.Diffusion.P2P as P2P
import qualified Ouroboros.Network.Diffusion.NonP2P as NonP2P
import           Ouroboros.Network.IOManager (withIOManager)
import           Ouroboros.Network.NodeToClient (LocalAddress (..), LocalSocket (..))
import           Ouroboros.Network.NodeToNode (RemoteAddress,
                   AcceptedConnectionsLimit (..), DiffusionMode, PeerSelectionTargets (..))
import           Ouroboros.Network.PeerSelection.LedgerPeers (UseLedgerAfter (..))
import           Ouroboros.Network.PeerSelection.RelayAccessPoint (RelayAccessPoint (..))
import qualified Shelley.Spec.Ledger.API as SL

import           Cardano.Api
import qualified Cardano.Api.Protocol.Types as Protocol

import           Cardano.Config.Git.Rev (gitRev)

import           Trace.Forward.Protocol.Type (NodeInfo)

import           Cardano.Node.Configuration.Socket (SocketOrSocketInfo (..),
                     gatherConfiguredSockets, getSocketOrSocketInfoAddr)
import qualified Cardano.Node.Configuration.TopologyP2P as TopologyP2P
import           Cardano.Node.Configuration.TopologyP2P
import qualified Cardano.Node.Configuration.Topology as TopologyNonP2P
import           Cardano.Node.Handlers.Shutdown
import           Cardano.Node.Protocol (mkConsensusProtocol)
import           Cardano.Node.Protocol.Types
import           Cardano.Tracing.Kernel
import           Cardano.Tracing.Peer
import           Cardano.Tracing.Tracers

{- HLINT ignore "Use fewer imports" -}

runNode
  :: PartialNodeConfiguration
  -> IO ()
runNode cmdPc = do
    now <- getCurrentTime
    -- TODO: Remove sodiumInit: https://github.com/input-output-hk/cardano-base/issues/175
    Crypto.sodiumInit

    configYamlPc <- parseNodeConfigurationFP . getLast $ pncConfigFile cmdPc

    nc <- case makeNodeConfiguration $ defaultPartialNodeConfiguration <> configYamlPc <> cmdPc of
            Left err -> panic $ "Error in creating the NodeConfiguration: " <> Text.pack err
            Right nc' -> return nc'

    putStrLn $ "Node configuration: " <> show @_ @Text nc

    case shelleyVRFFile $ ncProtocolFiles nc of
      Just vrfFp -> do vrf <- runExceptT $ checkVRFFilePermissions vrfFp
                       case vrf of
                         Left err ->
                           putTextLn (renderVRFPrivateKeyFilePermissionError err) >> exitFailure
                         Right () ->
                           pure ()
      Nothing -> pure ()

    eitherSomeProtocol <- runExceptT $ mkConsensusProtocol nc

    p :: SomeConsensusProtocol <-
      case eitherSomeProtocol of
        Left err -> putStrLn (displayError err) >> exitFailure
        Right p  -> pure p

    eLoggingLayer <- runExceptT $ createLoggingLayer
                     (ncTraceConfig nc)
                     (Text.pack (showVersion version))
                     nc
                     p

    loggingLayer <- case eLoggingLayer of
                      Left err  -> putTextLn (show err) >> exitFailure
                      Right res -> return res

    -- New logging initialisation
    let ekgServer' = ekgServer (llEKGDirect loggingLayer)
    let ekgStore = EKG.serverMetricStore ekgServer'
    loggerConfiguration <-
      case getLast $ pncConfigFile cmdPc of
        Just fileName -> NL.readConfiguration (unConfigPath fileName)
        Nothing -> putTextLn "No configuration file name found!" >> exitFailure
    baseTrace    <- NL.standardTracer
    nodeInfo <- prepareNodeInfo nc p loggerConfiguration now
    forwardSink <- withIOManager $ \iomgr ->
                        NL.initForwarding iomgr loggerConfiguration ekgStore nodeInfo
    let forwardTrace = NL.forwardTracer forwardSink
    ekgTrace   <- NL.ekgTracer (Left ekgStore)
    -- End new logging initialisation

    !trace <- setupTrace loggingLayer
    let tracer = contramap pack $ toLogObject trace

    logTracingVerbosity nc tracer

    let handleNodeWithTracers
          :: ( TraceConstraints blk
             , Protocol.Protocol IO blk
             )
          => Protocol.ProtocolInfoArgs IO blk
          -> IO ()
        handleNodeWithTracers runP = do
          -- This IORef contains node kernel structure which holds node kernel.
          -- Used for ledger queries and peer connection status.
          nodeKernelData <- mkNodeKernelData
          let ProtocolInfo { pInfoConfig = cfg } = Protocol.protocolInfo runP
          case ncEnableP2P nc of
            SomeNetworkP2PMode p2pMode -> do
              let fp = case getLast (pncConfigFile cmdPc) of
                          Just fileName -> unConfigPath fileName
                          Nothing       -> "No file path found!"
              bi <- getBasicInfo nc p fp

              tracers <- mkTracers
                          (Consensus.configBlock cfg)
                          (ncTraceConfig nc)
                          trace
                          nodeKernelData
                          (llEKGDirect loggingLayer)
                          p2pMode
              -- Couldn't resolve it.
              {-
              tracers <- mkDispatchTracers
                           (Consensus.configBlock cfg)
                           (ncTraceConfig nc)
                           trace
                           nodeKernelData
                           (Just (llEKGDirect loggingLayer))
                           baseTrace
                           forwardTrace
                           (Just ekgTrace)
                           loggerConfiguration
                           bi
              -}
              Async.withAsync (handlePeersListSimple trace nodeKernelData)
                  $ \_peerLogingThread ->
                    -- We ignore peer loging thread if it dies, but it will be killed
                    -- when 'handleSimpleNode' terminates.
                        handleSimpleNode p runP p2pMode trace tracers nc
                                        (setNodeKernel nodeKernelData)
                        `finally`
                        shutdownLoggingLayer loggingLayer

    case p of
      SomeConsensusProtocol _ runP -> handleNodeWithTracers runP

logTracingVerbosity :: NodeConfiguration -> Tracer IO String -> IO ()
logTracingVerbosity nc tracer =
  case ncTraceConfig nc of
    TracingOff -> return ()
    TracingOn traceConf ->
      case traceVerbosity traceConf of
        NormalVerbosity -> traceWith tracer "tracing verbosity = normal verbosity "
        MinimalVerbosity -> traceWith tracer "tracing verbosity = minimal verbosity "
        MaximalVerbosity -> traceWith tracer "tracing verbosity = maximal verbosity "
    TraceDispatcher _traceConf ->
      pure ()
-- | Add the application name and unqualified hostname to the logging
-- layer basic trace.
--
-- If the @CARDANO_NODE_LOGGING_HOSTNAME@ environment variable is set,
-- it overrides the system hostname. This is useful when running a
-- local test cluster with all nodes on the same host.
setupTrace
  :: LoggingLayer
  -> IO (Trace IO Text)
setupTrace loggingLayer = do
    hn <- maybe hostname (pure . pack) =<< lookupEnv "CARDANO_NODE_LOGGING_HOSTNAME"
    return $
        setHostname hn $
        llAppendName loggingLayer "node" (llBasicTrace loggingLayer)
  where
    hostname = do
      hn0 <- pack <$> getHostName
      return $ take 8 $ fst $ breakOn "." hn0

handlePeersListSimple
  :: Trace IO Text
  -> NodeKernelData blk
  -> IO ()
handlePeersListSimple tr nodeKern = forever $ do
  getCurrentPeers nodeKern >>= tracePeers tr
  threadDelay 2000000 -- 2 seconds.

isOldLogging :: TraceOptions -> Bool
isOldLogging TracingOff          = False
isOldLogging (TracingOn _)       = True
isOldLogging (TraceDispatcher _) = False

isNewLogging :: TraceOptions -> Bool
isNewLogging TracingOff          = False
isNewLogging (TracingOn _)       = False
isNewLogging (TraceDispatcher _) = True

-- | Sets up a simple node, which will run the chain sync protocol and block
-- fetch protocol, and, if core, will also look at the mempool when trying to
-- create a new block.

handleSimpleNode
  :: forall blk p2p
  . ( RunNode blk
    , Protocol.Protocol IO blk
    )
  => SomeConsensusProtocol
  -> Protocol.ProtocolInfoArgs IO blk
  -> NetworkP2PMode p2p
  -> Trace IO Text
  -> Tracers RemoteConnectionId LocalConnectionId blk p2p
  -> NodeConfiguration
  -> (NodeKernel IO RemoteConnectionId LocalConnectionId blk -> IO ())
  -- ^ Called on the 'NodeKernel' after creating it, but before the network
  -- layer is initialised.  This implies this function must not block,
  -- otherwise the node won't actually start.
  -> IO ()
handleSimpleNode scp runP p2pMode trace nodeTracers nc onKernel = do
  logStartupWarnings

  let pInfo = Protocol.protocolInfo runP

  if isOldLogging (ncTraceConfig nc)
    then createTracers nc trace
    else pure ()

  (publicIPv4SocketOrAddr, publicIPv6SocketOrAddr, localSocketOrPath) <- do
    result <- runExceptT (gatherConfiguredSockets nc)
    case result of
      Right triplet -> return triplet
      Left error -> do
        traceWith (startupTracer nodeTracers)
                $ StartupSocketConfigError error
        throwIO error

  dbPath <- canonDbPath nc

  let diffusionArguments :: Diffusion.Arguments Socket      RemoteAddress
                                                LocalSocket LocalAddress
      diffusionArguments =
        Diffusion.Arguments {
            Diffusion.daIPv4Address  =
              case publicIPv4SocketOrAddr of
                Just (ActualSocket socket) -> Just (Left socket)
                Just (SocketInfo addr)     -> Just (Right addr)
                Nothing                    -> Nothing
          , Diffusion.daIPv6Address  =
              case publicIPv6SocketOrAddr of
                Just (ActualSocket socket) -> Just (Left socket)
                Just (SocketInfo addr)     -> Just (Right addr)
                Nothing                    -> Nothing
          , Diffusion.daLocalAddress =
              case localSocketOrPath of  -- TODO allow expressing the Nothing case in the config
                Just (ActualSocket localSocket)  -> Just (Left  localSocket)
                Just (SocketInfo localAddr)      -> Just (Right localAddr)
                Nothing                          -> Nothing
          , Diffusion.daAcceptedConnectionsLimit =
              AcceptedConnectionsLimit
                { acceptedConnectionsHardLimit = 512
                , acceptedConnectionsSoftLimit = 384
                , acceptedConnectionsDelay     = 5
                }
          , Diffusion.daMode = ncDiffusionMode nc
          }

  ipv4 <- traverse getSocketOrSocketInfoAddr publicIPv4SocketOrAddr
  ipv6 <- traverse getSocketOrSocketInfoAddr publicIPv6SocketOrAddr

  if isOldLogging (ncTraceConfig nc)
    then do
      traceWith (startupTracer nodeTracers)
                (StartupInfo (catMaybes [ipv4, ipv6])
                             localSocketOrPath
                             ( limitToLatestReleasedVersion fst
                             . supportedNodeToNodeVersions
                             $ Proxy @blk
                             )
                             ( limitToLatestReleasedVersion snd
                             . supportedNodeToClientVersions
                             $ Proxy @blk
                             ))
    else if isNewLogging (ncTraceConfig nc)
      then do
        let bin = BasicInfoNetwork {
                    niAddresses     = catMaybes [ipv4, ipv6]
                  , niDiffusionMode = ncDiffusionMode $ nc
                  , niDnsProducers  = dnsProducers
                  , niIpProducers   = ipProducers
                  }
        traceWith (basicInfoTracer nodeTracers) (BINetwork bin)
      else pure ()

  withShutdownHandling nc trace $ \sfds ->
    let nodeArgs = RunNodeArgs
          { rnTraceConsensus = consensusTracers nodeTracers
          , rnTraceNTN       = nodeToNodeTracers nodeTracers
          , rnTraceNTC       = nodeToClientTracers nodeTracers
          , rnProtocolInfo   = pInfo
          , rnNodeKernelHook = \registry nodeKernel -> do
              maybeSpawnOnSlotSyncedShutdownHandler nc sfds trace registry
                (Node.getChainDB nodeKernel)
              onKernel nodeKernel
          , rnEnableP2P      = p2pMode
          }
    in case p2pMode of
      EnabledP2PMode -> do
        traceWith (startupTracer nodeTracers)
                  (StartupP2PInfo (ncDiffusionMode nc))
        nt <- TopologyP2P.readTopologyFileOrError nc
        let (localRoots, publicRoots) = producerAddresses nt
        traceWith (startupTracer nodeTracers)
                $ NetworkConfig localRoots
                                publicRoots
                                (useLedgerAfterSlot nt)
        (localRootsVar :: StrictTVar IO [(Int, Map RelayAccessPoint PeerAdvertise)])  <- newTVarIO localRoots
        publicRootsVar <- newTVarIO publicRoots
        useLedgerVar   <- newTVarIO (useLedgerAfterSlot nt)
#ifdef UNIX
        _ <- Signals.installHandler
              Signals.sigHUP
              (updateTopologyConfiguration localRootsVar publicRootsVar useLedgerVar)
              Nothing
#endif
        void $
          Node.run
            nodeArgs
            StdRunNodeArgs
              { srnBfcMaxConcurrencyBulkSync   = unMaxConcurrencyBulkSync <$> ncMaxConcurrencyBulkSync nc
              , srnBfcMaxConcurrencyDeadline   = unMaxConcurrencyDeadline <$> ncMaxConcurrencyDeadline nc
              , srnChainDbValidateOverride     = ncValidateDB nc
              , srnSnapshotInterval            = ncSnapshotInterval nc
              , srnDatabasePath                = dbPath
              , srnDiffusionArguments          = diffusionArguments
              , srnDiffusionArgumentsExtra     = mkP2PArguments nc (readTVar localRootsVar)
              (readTVar publicRootsVar)
              (readTVar useLedgerVar)
              , srnDiffusionTracers            = diffusionTracers nodeTracers
              , srnDiffusionTracersExtra       = diffusionTracersExtra nodeTracers
              , srnEnableInDevelopmentVersions = ncTestEnableDevelopmentNetworkProtocols nc
              , srnTraceChainDB                = chainDBTracer nodeTracers
              , srnMaybeMempoolCapacityOverride = ncMaybeMempoolCapacityOverride nc
              }
      DisabledP2PMode -> do
        eitherTopology <- TopologyNonP2P.readTopologyFile nc
        nt <- either (\err -> panic $ "Cardano.Node.Run.handleSimpleNodeNonP2P.readTopologyFile: " <> err) pure eitherTopology
        let (ipProducerAddrs, dnsProducerAddrs) = producerAddressesNonP2P nt

            dnsProducers :: [DnsSubscriptionTarget]
            dnsProducers = [ DnsSubscriptionTarget (Text.encodeUtf8 addr) port v
                           | (NodeAddress (NodeHostDnsAddress addr) port, v) <- dnsProducerAddrs
                           ]

            ipProducers :: IPSubscriptionTarget
            ipProducers = IPSubscriptionTarget
                           [ toSockAddr (addr, port)
                           | (NodeAddress (NodeHostIPAddress addr) port) <- ipProducerAddrs
                           ]
                           (length ipProducerAddrs)
        void $
          Node.run
            nodeArgs
            StdRunNodeArgs
              { srnBfcMaxConcurrencyBulkSync   = unMaxConcurrencyBulkSync <$> ncMaxConcurrencyBulkSync nc
              , srnBfcMaxConcurrencyDeadline   = unMaxConcurrencyDeadline <$> ncMaxConcurrencyDeadline nc
              , srnChainDbValidateOverride     = ncValidateDB nc
              , srnSnapshotInterval            = ncSnapshotInterval nc
              , srnDatabasePath                = dbPath
              , srnDiffusionArguments          = diffusionArguments
              , srnDiffusionArgumentsExtra     = mkNonP2PArguments ipProducers dnsProducers
              , srnDiffusionTracers            = diffusionTracers nodeTracers
              , srnDiffusionTracersExtra       = diffusionTracersExtra nodeTracers
              , srnEnableInDevelopmentVersions = ncTestEnableDevelopmentNetworkProtocols nc
              , srnTraceChainDB                = chainDBTracer nodeTracers
              , srnMaybeMempoolCapacityOverride = ncMaybeMempoolCapacityOverride nc
              }
 where
  logStartupWarnings :: IO ()
  logStartupWarnings = do
    (case p2pMode of
      DisabledP2PMode -> return ()
      EnabledP2PMode  -> do
        traceWith (startupTracer nodeTracers) P2PWarning
        when (not $ ncTestEnableDevelopmentNetworkProtocols nc)
          $ traceWith (startupTracer nodeTracers)
                      P2PWarningDevelopementNetworkProtocols
      ) :: IO () -- annoying, but unavoidable for GADT type inference

    let developmentNtnVersions =
          case latestReleasedNodeVersion (Proxy @blk) of
            (Just ntnVersion, _) -> filter (> ntnVersion)
                                  . Map.keys
                                  $ supportedNodeToNodeVersions (Proxy @blk)
            (Nothing, _)         -> Map.keys
                                  $ supportedNodeToNodeVersions (Proxy @blk)
        developmentNtcVersions =
          case latestReleasedNodeVersion (Proxy @blk) of
            (_, Just ntcVersion) -> filter (> ntcVersion)
                                  . Map.keys
                                  $ supportedNodeToClientVersions (Proxy @blk)
            (_, Nothing)         -> Map.keys
                                  $ supportedNodeToClientVersions (Proxy @blk)
    when (  ncTestEnableDevelopmentNetworkProtocols nc
         && (not (null developmentNtnVersions) || not (null developmentNtcVersions)) )
       $ traceWith (startupTracer nodeTracers)
                   (WarningDevelopmentNetworkProtocols
                     developmentNtnVersions
                     developmentNtcVersions)

  createTracers
    :: NodeConfiguration
    -> Trace IO Text
    -> IO ()
  createTracers NodeConfiguration { ncValidateDB }
                tr = do
    startTime <- getCurrentTime
    traceNodeBasicInfo tr =<< nodeBasicInfo nc scp startTime
    traceWith (startupTracer nodeTracers)
            $ StartupTime startTime
    when ncValidateDB $ traceWith (startupTracer nodeTracers) StartupDBValidation

  traceNodeBasicInfo :: Trace IO Text -> [LogObject Text] -> IO ()
  traceNodeBasicInfo tr basicInfoItems =
    forM_ basicInfoItems $ \(LogObject nm mt content) ->
      traceNamedObject (appendName nm tr) (mt, content)

#ifdef UNIX
  updateTopologyConfiguration :: StrictTVar IO [(Int, Map RelayAccessPoint PeerAdvertise)]
                              -> StrictTVar IO [RelayAccessPoint]
                              -> StrictTVar IO UseLedgerAfter
                              -> Signals.Handler
  updateTopologyConfiguration localRootsVar publicRootsVar useLedgerVar =
    Signals.Catch $ do
      traceWith (startupTracer nodeTracers) NetworkConfigUpdate
      result <- try $ readTopologyFileOrError nc
      case result of
        Left (FatalError err) ->
          traceWith (startupTracer nodeTracers)
                  $ NetworkConfigUpdateError
                  $ pack "Error reading topology configuration file:" <> err
        Right nt -> do
          let (localRoots, publicRoots) = producerAddresses nt
          traceWith (startupTracer nodeTracers)
                  $ NetworkConfig localRoots publicRoots (useLedgerAfterSlot nt)
          atomically $ do
            writeTVar localRootsVar localRoots
            writeTVar publicRootsVar publicRoots
            writeTVar useLedgerVar (useLedgerAfterSlot nt)
#endif

  limitToLatestReleasedVersion :: forall k v.
       Ord k
    => ((Maybe NodeToNodeVersion, Maybe NodeToClientVersion) -> Maybe k)
    -> Map k v
    -> Map k v
  limitToLatestReleasedVersion prj =
      if ncTestEnableDevelopmentNetworkProtocols nc then id
      else
      case prj $ latestReleasedNodeVersion (Proxy @blk) of
        Nothing       -> id
        Just version_ -> Map.takeWhileAntitone (<= version_)

--------------------------------------------------------------------------------
-- Helper functions
--------------------------------------------------------------------------------

canonDbPath :: NodeConfiguration -> IO FilePath
canonDbPath NodeConfiguration{ncDatabaseFile = DbFile dbFp} = do
  fp <- canonicalizePath =<< makeAbsolute dbFp
  createDirectoryIfMissing True fp
  return fp


-- | Make sure the VRF private key file is readable only
-- by the current process owner the node is running under.
checkVRFFilePermissions :: FilePath -> ExceptT VRFPrivateKeyFilePermissionError IO ()
#ifdef UNIX
checkVRFFilePermissions vrfPrivKey = do
  fs <- liftIO $ getFileStatus vrfPrivKey
  let fm = fileMode fs
  -- Check the the VRF private key file does not give read/write/exec permissions to others.
  when (hasOtherPermissions fm)
       (left $ OtherPermissionsExist vrfPrivKey)
  -- Check the the VRF private key file does not give read/write/exec permissions to any group.
  when (hasGroupPermissions fm)
       (left $ GroupPermissionsExist vrfPrivKey)
 where
  hasPermission :: FileMode -> FileMode -> Bool
  hasPermission fModeA fModeB = fModeA `intersectFileModes` fModeB /= nullFileMode

  hasOtherPermissions :: FileMode -> Bool
  hasOtherPermissions fm' = fm' `hasPermission` otherModes

  hasGroupPermissions :: FileMode -> Bool
  hasGroupPermissions fm' = fm' `hasPermission` groupModes
#else
checkVRFFilePermissions vrfPrivKey = do
  attribs <- liftIO $ getFileAttributes vrfPrivKey
  -- https://docs.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-createfilea
  -- https://docs.microsoft.com/en-us/windows/win32/fileio/file-access-rights-constants
  -- https://docs.microsoft.com/en-us/windows/win32/secauthz/standard-access-rights
  -- https://docs.microsoft.com/en-us/windows/win32/secauthz/generic-access-rights
  -- https://docs.microsoft.com/en-us/windows/win32/secauthz/access-mask
  when (attribs `hasPermission` genericPermissions)
       (left $ GenericPermissionsExist vrfPrivKey)
 where
  genericPermissions = gENERIC_ALL .|. gENERIC_READ .|. gENERIC_WRITE .|. gENERIC_EXECUTE
  hasPermission fModeA fModeB = fModeA .&. fModeB /= gENERIC_NONE
#endif


mkP2PArguments
  :: NodeConfiguration
  -> STM IO [(Int, Map RelayAccessPoint PeerAdvertise)]
     -- ^ non-overlapping local root peers groups; the 'Int' denotes the
     -- valency of its group.
  -> STM IO [RelayAccessPoint]
  -> STM IO UseLedgerAfter
  -> Diffusion.ExtraArguments 'Diffusion.P2P IO
mkP2PArguments NodeConfiguration {
                 ncTargetNumberOfRootPeers,
                 ncTargetNumberOfKnownPeers,
                 ncTargetNumberOfEstablishedPeers,
                 ncTargetNumberOfActivePeers,
                 ncProtocolIdleTimeout,
                 ncTimeWaitTimeout
               }
               daReadLocalRootPeers
               daReadPublicRootPeers
               daReadUseLedgerAfter =
    Diffusion.P2PArguments P2P.ArgumentsExtra
      { P2P.daPeerSelectionTargets
      , P2P.daReadLocalRootPeers
      , P2P.daReadPublicRootPeers
      , P2P.daReadUseLedgerAfter
      , P2P.daProtocolIdleTimeout = ncProtocolIdleTimeout
      , P2P.daTimeWaitTimeout     = ncTimeWaitTimeout
      }
  where
    daPeerSelectionTargets = PeerSelectionTargets {
        targetNumberOfRootPeers        = ncTargetNumberOfRootPeers,
        targetNumberOfKnownPeers       = ncTargetNumberOfKnownPeers,
        targetNumberOfEstablishedPeers = ncTargetNumberOfEstablishedPeers,
        targetNumberOfActivePeers      = ncTargetNumberOfActivePeers
    }

mkNonP2PArguments
  :: IPSubscriptionTarget
  -> [DnsSubscriptionTarget]
  -> Diffusion.ExtraArguments 'Diffusion.NonP2P m
mkNonP2PArguments daIpProducers daDnsProducers =
    Diffusion.NonP2PArguments NonP2P.ArgumentsExtra
      { NonP2P.daIpProducers
      , NonP2P.daDnsProducers
      }

-- | TODO: Only needed for enabling P2P switch
--
producerAddressesNonP2P
  :: TopologyNonP2P.NetworkTopology
  -> ( [NodeIPAddress]
     , [(NodeDnsAddress, Int)])
producerAddressesNonP2P nt =
  case nt of
    TopologyNonP2P.RealNodeTopology producers' ->
        partitionEithers
      . mapMaybe TopologyNonP2P.remoteAddressToNodeAddress
      $ producers'
    TopologyNonP2P.MockNodeTopology nodeSetup ->
        partitionEithers
      . mapMaybe TopologyNonP2P.remoteAddressToNodeAddress
      . concatMap TopologyNonP2P.producers
      $ nodeSetup

producerAddresses
  :: NetworkTopology
  -> ([(Int, Map RelayAccessPoint PeerAdvertise)], [RelayAccessPoint])
producerAddresses nt =
  case nt of
    RealNodeTopology lrpg prp _ ->
      ( map (\lrp -> ( valency lrp
                     , Map.fromList $ rootConfigToRelayAccessPoint
                                    $ localRoots lrp
                     )
            )
            (groups lrpg)
      , concatMap (map fst . rootConfigToRelayAccessPoint)
                  (map publicRoots prp)
      )

useLedgerAfterSlot
  :: NetworkTopology
  -> UseLedgerAfter
useLedgerAfterSlot (RealNodeTopology _ _ (UseLedger ul)) = ul

-- | Prepare basic info about the node. This info will be sent to 'cardano-tracer'.
prepareNodeInfo
  :: NodeConfiguration
  -> SomeConsensusProtocol
  -> NL.TraceConfig
  -> UTCTime
  -> IO NodeInfo
prepareNodeInfo nc (SomeConsensusProtocol whichP pForInfo) tc nodeStartTime = do
  nodeName <- prepareNodeName
  return $ NodeInfo
    { niName            = nodeName
    , niProtocol        = pack . protocolName $ ncProtocol nc
    , niVersion         = pack . showVersion $ version
    , niCommit          = gitRev
    , niStartTime       = nodeStartTime
    , niSystemStartTime = systemStartTime
    }
 where
  cfg = pInfoConfig $ Protocol.protocolInfo pForInfo

  systemStartTime :: UTCTime
  systemStartTime =
    case whichP of
      Protocol.ByronBlockType ->
        getSystemStartByron
      Protocol.ShelleyBlockType ->
        let DegenLedgerConfig cfgShelley = Consensus.configLedger cfg
        in getSystemStartShelley cfgShelley
      Protocol.CardanoBlockType ->
        let CardanoLedgerConfig _ cfgShelley cfgAllegra cfgMary cfgAlonzo = Consensus.configLedger cfg
        in minimum [ getSystemStartByron
                   , getSystemStartShelley cfgShelley
                   , getSystemStartShelley cfgAllegra
                   , getSystemStartShelley cfgMary
                   , getSystemStartShelley cfgAlonzo
                   ]

  getSystemStartByron = WCT.getSystemStart . getSystemStart . Consensus.configBlock $ cfg
  getSystemStartShelley cfg' = SL.sgSystemStart . shelleyLedgerGenesis . shelleyLedgerConfig $ cfg'

  prepareNodeName =
    case NL.tcNodeName tc of
      Just aName -> return aName
      Nothing    -> pack <$> getHostName
