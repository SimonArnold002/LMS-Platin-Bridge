package Slim::Utils::IPDetect;
# On Simon's server this answers 127.0.0.1 (loopback), NOT the LAN address -
# which is why Plugin.pm must let the server address be overridden. A url built
# from a loopback address is unreachable from the Hub.
sub IP { return '127.0.0.1' }
1;
