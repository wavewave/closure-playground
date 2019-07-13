module Main where

{-
-- prototype pseudocode
process :: IO ()
process =
  master nodeList $ do
    chs <- replicateM 10 mkChan
    let sps = map fst chs -- send ports
        rps = map snd chs -- receive ports
        sp0 = head sps
        rpn = last rps
    let pairs = zip (tail sps) rps   -- (s_(i+1), r_i)
    for_ pairs $ \(s',r) -> do
      action s r'

    send sp0 "1234"
    r <- recv rpn
    print r


action s r' = do
  msg <- recv r'
  send s msg
-}

main :: IO ()
main = do
  putStrLn "ring"
