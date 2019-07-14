{-# LANGUAGE BangPatterns       #-}
{-# LANGUAGE DeriveGeneric      #-}
{-# LANGUAGE ExplicitNamespaces #-}
{-# LANGUAGE OverloadedStrings  #-}
{-# LANGUAGE TupleSections      #-}
{-# LANGUAGE TypeApplications   #-}

module Control.Distributed.Playground.MasterSlave where

import Control.Concurrent.STM (atomically,modifyTVar')
import Control.Monad (forever,guard,void)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Loops (whileJust_)
import Control.Monad.Trans.Reader (ask)
import Data.Binary (Binary)
import Data.Foldable (for_,traverse_)
import qualified Data.HashMap.Strict as HM
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
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
import Control.Distributed.Playground.Request ( Request(..)
                                              , SomeRequest(..)
                                              , handleRequest
                                              , reqChanId
                                              , peerChanId
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
requestHandler :: M r
requestHandler = do
  Just (_,rp_req) <- newChanWithId reqChanId
  forever $ do
    SomeRequest req <- receiveChan rp_req
    let (sp_sp,sp_ans) = case req of
                           PureRequest _ sp_sp' sp_ans' -> (sp_sp',sp_ans')
                           MRequest    _ sp_sp' sp_ans' -> (sp_sp',sp_ans')
    (sp_input,rp_input) <- newChan
    logText $ "sp_input sent:"
    sendChan sp_sp sp_input
    whileJust_ (receiveChan rp_input) $ \input -> do
      logText $ "requested for input: " <> T.pack (show input)
      ans <- handleRequest req input
      logText $ "request handled with answer: " <> T.pack (show ans)
      sendChan sp_ans ans
      logText $ "answer sent"

-- | Handling peer-to-peer network
peerNetworkHandler :: M r
peerNetworkHandler = do
  Just (_,rp_peer) <- newChanWithId @Peer peerChanId
  ref_pool <- chSockets <$> ask
  myname <- getSelfName
  forever $ do
    Peer peername (peerhost,peerport)  <- receiveChan rp_peer
    logText $ "connect to peer: " <> unNodeName peername
    (sock,addr) <- liftIO $ establishConnection myname (peerhost,peerport)
    liftIO $
      atomically $
        modifyTVar' ref_pool $ \(SocketPool pool) ->
          SocketPool (HM.insert peername (sock,addr) pool)

-- | Slave node main event loop.
slave :: NodeName -> HostName -> ServiceName -> IO ()
slave node hostName serviceName = do
  putStrLn "Waiting for connection from master."
  serve (Host hostName) serviceName $ \(sock, remoteAddr) -> do
    putStrLn $ "TCP connection established from " ++ show remoteAddr
    mname <- fmap (fromMsg @NodeName) <$> recvMsg sock
    case mname of
      Just (NodeName name) ->
        if name == "master"
          then do
            let pool = SocketPool $ HM.fromList [(NodeName name,(sock,remoteAddr))]
            TIO.putStrLn $ "Connected client is " <> name <> ". Start process!"
            runManaged node pool $ do
              void $ forkIO $ peerNetworkHandler
              requestHandler
          else do
            -- placeholder for peer discovery.
            TIO.putStrLn $ "Connected client is " <> name <> ", but cannot handle it yet"
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

-- | Master node event loop.
master :: [(NodeName,(HostName,ServiceName))] -> M a -> IO a
master slaveList task = do
  pool <-
    SocketPool . HM.fromList <$>
      traverse (\(n,(h,s)) -> fmap (n,) (establishConnection (NodeName "master") (h,s))) slaveList
  r <- runManaged (NodeName "master") pool $
         connectPeers slaveList >> task

  traverse_ (closeSock . fst) $ sockPoolMap pool
  pure r
