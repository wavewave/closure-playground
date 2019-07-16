#!/bin/sh

( cabal new-run ring slave0 1> log0_out.txt 2> log0_err.txt &
  cabal new-run ring slave1 1> log1_out.txt 2> log1_err.txt &
  cabal new-run ring slave2 1> log2_out.txt 2> log2_err.txt &
  cabal new-run ring slave3 1> log3_out.txt 2> log3_err.txt &
  cabal new-run ring slave4 1> log4_out.txt 2> log4_err.txt )


