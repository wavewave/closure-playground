#!/bin/sh

( cabal new-run ring slave1 1> log1_out.txt 2> log1_err.txt &
  cabal new-run ring slave2 1> log2_out.txt 2> log2_err.txt &
  cabal new-run ring slave3 1> log3_out.txt 2> log3_err.txt )


