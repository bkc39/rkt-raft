((raft-version) (values "\"26.08.00\"\n") "" "")
((match-define
  (raft-abi #:raft raft #:rmm rmm #:cccl cccl #:cuda-runtime cuda-runtime)
  (raft-abi))
 (values "")
 ""
 "")
((printf
  "raft ~a\nrmm ~a\ncccl ~a\ncuda-runtime ~a\n"
  raft
  rmm
  cccl
  cuda-runtime)
 (values "")
 "raft 26.08.00\nrmm 26.08.00\ncccl 3.4.3\ncuda-runtime 13.2\n"
 "")
((device-count) (values "1\n") "" "")
