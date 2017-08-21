Repository containing the Scalaris snapshot and the raw data of the benchmarks
used in my  master's thesis.

The PRBR implementation can be found in scalaris/rbr/.
rbrcset.erl and prbr.erl are the implementation of the proposer and
acceptor processes, respectively.

- The master branch represents the unmodified version of PRBR.
- The rr_commute branch implements changes of Section 8.2 (commutative reads).
- The rw_commute branch implements changes of Section 8.2 and 8.3 (reads commuting with writes)
- The ww_commute branch is the extension of PRBR to c-sets (commutative writes - Section 8.4)
