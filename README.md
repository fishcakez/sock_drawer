sock_drawer
===========

VERY experimental, customisable OTP socket manager (currently only an acceptor pool):

Do not use, very poorly tested but many features:

* All processes fully OTP compliant (only uses OTP behaviours)
* All processes supervised using supervisor module
* Atomically reconfigure pool just with a code change
* Swap listen socket without killing old connections
* Purge old connections
* Swap default implementation of most processes with custom module
* Accept/connect agnostic
* Graceful shutdown of connections



