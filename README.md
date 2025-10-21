A (mostly) Odin native HTTP/2 + TLS server. This is still a shitty first version so be nice about my code.

Currently 1.5 million requests / second on intel core ultra 7

```
valkyrie master  ? ❯ h2load -n 10000000 -c 500 -t 20 https://localhost:8443
starting benchmark...
spawning thread #0: 25 total client(s). 500000 total requests
spawning thread #1: 25 total client(s). 500000 total requests
spawning thread #2: 25 total client(s). 500000 total requests
spawning thread #3: 25 total client(s). 500000 total requests
spawning thread #4: 25 total client(s). 500000 total requests
spawning thread #5: 25 total client(s). 500000 total requests
spawning thread #6: 25 total client(s). 500000 total requests
spawning thread #7: 25 total client(s). 500000 total requests
spawning thread #8: 25 total client(s). 500000 total requests
spawning thread #9: 25 total client(s). 500000 total requests
spawning thread #10: 25 total client(s). 500000 total requests
spawning thread #11: 25 total client(s). 500000 total requests
spawning thread #12: 25 total client(s). 500000 total requests
spawning thread #13: 25 total client(s). 500000 total requests
spawning thread #14: 25 total client(s). 500000 total requests
spawning thread #15: 25 total client(s). 500000 total requests
spawning thread #16: 25 total client(s). 500000 total requests
spawning thread #17: 25 total client(s). 500000 total requests
spawning thread #18: 25 total client(s). 500000 total requests
spawning thread #19: 25 total client(s). 500000 total requests
TLS Protocol: TLSv1.2
Cipher: ECDHE-RSA-AES128-GCM-SHA256
Server Temp Key: ECDH prime256v1 256 bits
Application protocol: h2
progress: 10% done
progress: 20% done
progress: 30% done
progress: 40% done
progress: 50% done
progress: 60% done
progress: 70% done
progress: 80% done
progress: 90% done
progress: 100% done

finished in 6.44s, 1552175.13 req/s, 199.84MB/s
requests: 10000000 total, 10000000 started, 10000000 done, 10000000 succeeded, 0 failed, 0 errored, 0 timeout
status codes: 10000000 2xx, 0 3xx, 0 4xx, 0 5xx
traffic: 1.26GB (1350034500) total, 28.62MB (30007500) headers (space savings 93.88%), 1.06GB (1140000000) data
                     min         max         mean         sd        +/- sd
time for request:        7us     15.78ms       218us       683us    94.74%
time for connect:    41.86ms     71.20ms     52.63ms      5.10ms    68.20%
time to 1st byte:    42.02ms     72.59ms     53.26ms      5.22ms    66.80%
req/s           :    3111.43     5789.46     3888.19      526.53    67.60%  
```
