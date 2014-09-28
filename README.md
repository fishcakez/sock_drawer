sock_drawer
===========
Highly customisable OTP socket manager.

Warning
-------
`sock_drawer` is an experiment.

Features
--------
* Atomically reconfigure pool the same way as a supervisor
* Swap listen socket without closing old connections
* Swap socket handler module without closing old connections
* Change socket options without closing old connections
* Purge old connections
* Graceful shutdown
* Swap default implementation of most processes with custom module
* Accept/connect agnostic
* Property statem test
* All processes use OTP behaviours
* All processes supervised using supervisor module

Planned Features
----------------
* Documentation
* Examples
* Connection queue manager for client pools
* Unix socket support using `afunix`

Acceptor Pool Architecture
--------------------------
`sock_drawer` uses acceptor processes that spawn a handler and then
accept a connection before passing the process to the handler. The
manager process `sd_simple` supervises the sockets (`inet_tcp` ports),
instead of the handler processes. Handler processes are supervised by
a pool of supervisors (one supervisor per scheduler).

A group of acceptor processes can be swapped for another group by
temporarily running two groups side by side. This allows changing all
parts of the pool (except the manager) while keeping old connection
handlers alive. New handlers are supervised by new supervisors, allowing
old handlers to be identified (and messaged or shutdown seperately).

Benchmark
---------
Quick, pointless benchmark of cowboy example `hello_world` with
`max_keepalive` `1` using `wrk` over private network between 4-core
8GB-RAM Digital Ocean VMs.

`ranch` (100 acceptors):
```
Running 30s test @ http://10.*:8081/
  4 threads and 400 connections
  Thread Stats   Avg      Stdev     Max   +/- Stdev
    Latency    20.69ms   23.69ms 461.19ms   98.47%
    Req/Sec     2.49k   731.49     5.13k    68.55%
  295752 requests in 30.00s, 42.03MB read
  Socket errors: connect 0, read 0, write 0, timeout 15
Requests/sec:   9859.66
Transfer/sec:      1.40MB
```

`sock_drawer` (100 acceptors):
```
Running 30s test @ http://10.*:8080/
  4 threads and 400 connections
  Thread Stats   Avg      Stdev     Max   +/- Stdev
    Latency    14.79ms   21.97ms 474.12ms   98.54%
    Req/Sec     3.17k     0.92k    6.83k    66.79%
  374886 requests in 29.99s, 53.27MB read
  Socket errors: connect 0, read 0, write 0, timeout 15
Requests/sec:  12499.00
Transfer/sec:      1.78MB
```

`sock_drawer` is much more complex than `ranch` and so would recommend
`ranch`.
