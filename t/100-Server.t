use v6;
use lib 't';
use Test-support;
use Test;
use MongoDB;
use MongoDB::Client;
use MongoDB::Server;
use MongoDB::Socket;
#use MongoDB::Database;
#use MongoDB::Collection;
use MongoDB::Object-store;

#-------------------------------------------------------------------------------
#set-logfile($*OUT);
set-exception-process-level(MongoDB::Severity::Info);
info-message("Test $?FILE start");

my MongoDB::Client $client;
my BSON::Document $req;
my BSON::Document $doc;

#-------------------------------------------------------------------------------
subtest {

  $client .= new(:uri('mongodb://localhost:' ~ 65535));
  is $client.^name, 'MongoDB::Client', "Client isa {$client.^name}";
  my Str $reservation-code = $client.select-server;
  nok $reservation-code.defined, 'No servers selected';

}, "Connect failure testing";

#-------------------------------------------------------------------------------
subtest {

  $client = get-connection();
  my Str $reservation-code = $client.select-server;
  my MongoDB::Server $server = get-stored-object($reservation-code);
  ok $server.defined, 'Connection available';
  is $server.max-sockets, 3, "Maximum socket $server.max-sockets()";

  my MongoDB::Socket $socket = $server.get-socket;
  ok $socket.is-open, 'Socket is open';
  $socket.close;
  nok $socket.is-open, 'Socket is closed';

  try {
    my @skts;
    for ^10 {
      my $s = $server.get-socket;

      # Still below max
      #
      @skts.push($s);

      CATCH {
        when MongoDB::Message {
          ok .message ~~ m:s/Too many sockets 'opened,' max is/,
             "Too many sockets opened, max is $server.max-sockets()";

          for @skts { .close; }
          last;
        }
      }
    }
  }

  try {
    $server.max-sockets = 5;
    is $server.max-sockets, 5, "Maximum socket $server.max-sockets()";

    my @skts;
    for ^10 {
      my $s = $server.get-socket;

      # Still below max
      #
      @skts.push($s);

      CATCH {
        when MongoDB::Message {
          ok .message ~~ m:s/Too many sockets 'opened,' max is/,
             "Too many sockets opened, max is $server.max-sockets()";

          for @skts { .close; }
          last;
        }
      }
    }
  }

  try {
    $server.max-sockets = 2;

    CATCH {
      default {
        ok .message ~~ m:s/Type check failed in assignment to '$!max-sockets'/,
           "Type check failed in assignment to \$!max-sockets";
      }
    }
  }
}, 'Client, Server, Socket tests';

#`{{
#-------------------------------------------------------------------------------
subtest {

  # Create databases with a collection and data to make sure the databases are
  # there
  #
  $client = get-connection();
  my MongoDB::Database $database .= $client.database(:name<test>);
  isa-ok( $database, 'MongoDB::Database');

  my MongoDB::Collection $collection = $database.collection('abc');
  $req .= new: (
    insert => $collection.name,
    documents => [ (:name('MT'),), ]
  );

  $doc = $database.run-command($req);
  is $doc<ok>, 1, "Result is ok";

  # Drop database db2
  #
  $doc = $database.run-command: (dropDatabase => 1);
  is $doc<ok>, 1, 'Drop request ok';

}, "Create database, collection. Collect database info, drop data";
}}

#-------------------------------------------------------------------------------
# Cleanup
#
info-message("Test $?FILE end");
done-testing();
exit(0);
