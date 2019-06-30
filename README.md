closure-playground
==================

Lightweight cloud-haskell-like distributed processes with distributed-closure


To test,
```
$ nix-shell
$ cabal new-run ping slave1  # on one CLI terminal
$ cabal new-run ping slave2  # on another CLI terminal
$ cabal new-run ping master  # on yet another CLI terminal
```
then, you will see tasks from master will be distributed to slave1 and slave2 and master gets answer.
