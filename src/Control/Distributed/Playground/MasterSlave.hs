{-# LANGUAGE BangPatterns       #-}
{-# LANGUAGE DeriveGeneric      #-}
{-# LANGUAGE ExplicitNamespaces #-}
{-# LANGUAGE OverloadedStrings  #-}
{-# LANGUAGE TupleSections      #-}
{-# LANGUAGE TypeApplications   #-}

module Control.Distributed.Playground.MasterSlave where

import Control.Concurrent (newEmptyMVar,takeMVar)
import Control.Concurrent.STM (TVar,atomically,modifyTVar',newTVarIO,readTVar,readTVarIO,retry)
import Control.Monad (forever,guard,void)
import Control.Monad.IO.Class (MonadIO(liftIO))
import Control.Monad.Loops (whileJust_)
import Control.Monad.Trans.Reader (ask)
import Data.Binary (Binary)
import Data.Foldable (for_,traverse_)
import qualified Data.HashMap.Strict as HM
import qualified Data.Text as T
import Data.Traversable (traverse)
import GHC.Generics (Generic)
import Network.Simple.TCP ( HostPreference(Host)
                          , type HostName
                          , type ServiceName
                          , Socket
                          , SockAddr
                          , connectSock
                          , closeSock
                          , serve
                          )
import UnliftIO.Concurrent ( forkIO )
--
import Control.Distributed.Playground.Comm    ( M
                                              , NodeName(..)
                                              , SocketPool(..)
                                              , SPort(..)
                                              , RPort(..)
                                              , ChanState(..)
                                              , fromMsg
                                              , toMsg
                                              , recvMsg
                                              , sendMsg
                                              , receiveChan
                                              , sendChan
                                              , newChan
                                              , newChanWithId
                                              , runManaged
                                              , logText
                                              , getSelfName
                                              )
import Control.Distributed.Playground.P2P     ( SendP2PProto(..)
                                              , SendP2P(..)
                                              , P2PBrokerRequest(..)
                                              )
import Control.Distributed.Playground.Request ( Request(..)
                                              , SomeRequest(..)
                                              , handleRequest
                                              , reqChanId
                                              , peerChanId
                                              , peerReqChanId
                                              )


data Peer = Peer NodeName (HostName,ServiceName) deriving (Show,Generic)

instance Binary Peer

-- | Establish a conection with a node.
establishConnection :: NodeName -> (String,ServiceName) -> IO (Socket,SockAddr)
establishConnection myname (host,port) = do
  (sock,sockAddr) <- connectSock host port
  sendMsg sock (toMsg (myname :: NodeName))
  pure (sock,sockAddr)

-- | Main request handler in slave
requestHandler :: M ()
requestHandler = do
  Just (_,rp_req) <- newChanWithId reqChanId
  forever $ do
    SomeRequest req <- receiveChan rp_req
    let (sp_sp,sp_ans) = case req of
                           PureRequest _ sp_sp' sp_ans' -> (sp_sp',sp_ans')
                           MRequest    _ sp_sp' sp_ans' -> (sp_sp',sp_ans')
    (sp_input,rp_input) <- newChan
    -- logText $ "sp_input sent:"
    sendChan sp_sp sp_input
    whileJust_ (receiveChan rp_input) $ \input -> do
      -- logText $ "requested for input: " <> T.pack (show input)
      ans <- handleRequest req input
      -- logText $ "request handled with answer: " <> T.pack (show ans)
      sendChan sp_ans ans
      -- logText $ "answer sent"

-- | Insert socket into pool
insertIntoPool :: (MonadIO m) => TVar SocketPool -> NodeName -> (Socket,SockAddr) -> m ()
insertIntoPool ref_pool name (sock,addr) =
  liftIO $
    atomically $
      modifyTVar' ref_pool $ \(SocketPool pool) ->
        SocketPool (HM.insert name (sock,addr) pool)

-- | Handling peer-to-peer network
peerNetworkHandler :: M r
peerNetworkHandler = do
  Just (_,rp_peer) <- newChanWithId @Peer peerChanId
  ref_pool <- chSockets <$> ask
  myname <- getSelfName
  forever $ do
    Peer peername (peerhost,peerport)  <- receiveChan rp_peer
    -- logText $ "connect to peer: " <> unNodeName peername
    (sock,addr) <- liftIO $ establishConnection myname (peerhost,peerport)
    insertIntoPool ref_pool peername (sock,addr)

-- | Slave node main event loop.
slave :: NodeName -> HostName -> ServiceName -> IO ()
slave node hostName serviceName = do
  -- putStrLn "Waiting for connection from master."
  ref_pool <- newTVarIO $ SocketPool HM.empty

  serve (Host hostName) serviceName $ \(sock, addr) -> do
    -- putStrLn $ "TCP connection established from " ++ show addr
    mname <- fmap (fromMsg @NodeName) <$> recvMsg sock
    case mname of
      Just name ->
        if unNodeName name == "master"
          then do
            insertIntoPool ref_pool name (sock,addr)
            -- TIO.putStrLn $ "Connected client is " <> unNodeName name <> ". Start process!"
            runManaged node ref_pool $ do
              void $ forkIO $ peerNetworkHandler
              void $ requestHandler
          else do
            insertIntoPool ref_pool name (sock,addr)
            -- for idling
            v <- newEmptyMVar
            () <- takeMVar v
            pure ()
            -- TIO.putStrLn $ "added connected client: " <> unNodeName name
      Nothing -> error "should not happen"

-- | Populate connection pool of each slave with their peers.
connectPeers :: [(NodeName,(HostName,ServiceName))] -> M ()
connectPeers slaveList = do
  let peers = do
        (p1,_) <- slaveList
        (p2,addr2) <- slaveList
        guard (p1 < p2)
        pure (p1,Peer p2 addr2)
  for_ peers $ \(p1,cmd) -> do
    let sp = SPort p1 peerChanId
    sendChan sp cmd


p2pBroker :: RPort P2PBrokerRequest -> M ()
p2pBroker rp = do
  ref_chan <- liftIO $ newTVarIO HM.empty
  forever $ do
    req <- receiveChan rp
    case req of
      AddP2PChannel sp2p -> do
        let i = sp2pChanId sp2p
        liftIO $ atomically $ modifyTVar' ref_chan (HM.insert i sp2p)
        m <- liftIO $ readTVarIO ref_chan
        logText "AddP2PChannel"
        logText (T.pack (show (HM.keys m)))
      GetP2PChannel sproto sp -> do
        logText "GetP2PChannel"
        void $ forkIO $ do
          sp2p <-
            liftIO $ atomically $ do
              chan <- readTVar ref_chan
              case HM.lookup (sprotoChanId sproto) chan of
                Nothing -> retry
                Just sp2p -> pure sp2p
          logText $ "sp2p id = " <> T.pack (show (sp2pChanId sp2p))
          sendChan sp sp2p
          logText "GetP2PChannel, sent"
    -- liftIO $ threadDelay 1200000


-- | Master node event loop.
master :: [(NodeName,(HostName,ServiceName))] -> M a -> IO a
master slaveList task = do
  pool <-
    SocketPool . HM.fromList <$>
      traverse (\(n,(h,s)) -> fmap (n,) (establishConnection (NodeName "master") (h,s))) slaveList
  ref_pool <- newTVarIO pool
  r <- runManaged (NodeName "master") ref_pool $ do
         Just (_,rp_pinfo) <- newChanWithId peerReqChanId
         connectPeers slaveList
         void $ forkIO $ p2pBroker rp_pinfo
         task

  traverse_ (closeSock . fst) . sockPoolMap =<< readTVarIO ref_pool
  pure r
