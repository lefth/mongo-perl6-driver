use v6;

use MongoDB;
use MongoDB::Wire;
use MongoDB::Server::Monitor;
use MongoDB::Server::Socket;
use MongoDB::Authenticate::Credential;
use MongoDB::Authenticate::Scram;

use BSON::Document;
use Semaphore::ReadersWriters;
use Auth::SCRAM;

#-------------------------------------------------------------------------------
unit package MongoDB:auth<github:MARTIMM>;

#-------------------------------------------------------------------------------
class Server {

  # Used by Socket
  has Str $.server-name;
  has PortType $.server-port;

  has ClientType $!client;

  # As in MongoDB::Uri without servers name and port. So there are
  # database, username, password and options
  has Hash $!uri-data;
  has MongoDB::Authenticate::Credential $!credential;

  has MongoDB::Server::Socket @!sockets;

  # Server status data. Must be protected by a semaphore because of a thread
  # handling monitoring data.
  has Hash $!server-sts-data;
  has Semaphore::ReadersWriters $!rw-sem;
  has Tap $!server-tap;

  #-----------------------------------------------------------------------------
  # Server must make contact first to see if server exists and reacts. This
  # must be done in the background so Client starts this process in a thread.
  #
  submethod BUILD (
    ClientType:D :$!client,
    Str:D :$server-name,
    Hash :$!uri-data = %(),
  ) {

    $!rw-sem .= new;
#    $!rw-sem.debug = True;
    $!rw-sem.add-mutex-names(
      <s-select s-status>,
      :RWPatternType(C-RW-WRITERPRIO)
    ) unless $!rw-sem.check-mutex-names(<s-select s-status>);

#    $!client = $client;
#    $!uri-data = $client.uri-data;
    $!credential := $!client.credential;

    @!sockets = ();

    # Save name and port of the server
    ( my $host, my $port) = split( ':', $server-name);
    $!server-name = $host;
    $!server-port = $port.Int;

    $!server-sts-data = {
      :status(SS-Unknown), :!is-master, :error(''),
    };
  }

  #-----------------------------------------------------------------------------
  # Server initialization
  method server-init ( ) {

    # Start monitoring
    MongoDB::Server::Monitor.instance.register-server(self);

    # Tap into monitor data
    $!server-tap = self.tap-monitor( -> Hash $monitor-data {

#note "\n$*THREAD.id() In server, data from Monitor: ", ($monitor-data // {}).perl;

        # See also https://github.com/mongodb/specifications/blob/master/source/server-discovery-and-monitoring/server-discovery-and-monitoring.rst#parsing-an-ismaster-response
        try {

          my Bool $is-master = False;
          my ServerStatus $server-status = SS-Unknown;

          # test monitor defined boolean field ok
          if $monitor-data<ok> {

            # Used to get a socket an decide on type of authentication
            my $mdata = $monitor-data<monitor>;

            # test mongod server defined field ok for state of returned document
            # this is since newer servers return info about servers going down
            if $mdata<ok> == 1e0 {
#note "MData: $monitor-data.perl()";
              ( $server-status, $is-master) = self!process-status($mdata);

              $!rw-sem.writer( 's-status', {
                  $!server-sts-data = {
                    :status($server-status), :$is-master, :error(''),
                    :max-wire-version($mdata<maxWireVersion>.Int),
                    :min-wire-version($mdata<minWireVersion>.Int),
                    :weighted-mean-rtt-ms($monitor-data<weighted-mean-rtt-ms>),
                  }
                } # writer block
              ); # writer
            } # if $mdata<ok> == 1e0
          } # if $monitor-data<ok>

          # Server did not respond or returned an error
          else {

            $!rw-sem.writer( 's-status', {
                if $monitor-data<reason>:exists {
                  $!server-sts-data<error> = $monitor-data<reason>;
                }

                else {
                  $!server-sts-data<error> = 'Server did not respond';
                }

                $!server-sts-data<is-master> = False;
                $!server-sts-data<status> = SS-Unknown;

              } # writer block
            ); # writer
          }

          # Set the status with the new value
          debug-message("set status of {self.name()} $server-status");

          # Let the client find the topology using all found servers
          # in the same rhythm as the heartbeat loop of the monitor
          # (of each server)
          $!client.process-topology;

          CATCH {
            default {
              .note;

              # Set the status with the  value
              error-message("{.message}, {self.name()} {SS-Unknown}");
              $!rw-sem.writer( 's-status', {
                  $!server-sts-data = {
                    :status(SS-Unknown), :!is-master, :error(.message),
                  }
                } # block
              ); # writer
            } # default
          } # CATCH
        } # try
      } # tap block
    ); # tap
  } # method

  #-----------------------------------------------------------------------------
  method !process-status ( BSON::Document $mdata --> List ) {

    my Bool $is-master = False;
    my ServerStatus $server-status = SS-Unknown;

    # Shard server
    if $mdata<msg>:exists and $mdata<msg> eq 'isdbgrid' {
      $server-status = SS-Mongos;
    }

    # Replica server in preinitialization state
    elsif ? $mdata<isreplicaset> {
      $server-status = SS-RSGhost;
    }

    elsif ? $mdata<setName> {
      $is-master = ? $mdata<ismaster>;
      if $is-master {
        $server-status = SS-RSPrimary;
        $!client.add-servers([|@($mdata<hosts>),]) if $mdata<hosts>:exists;
      }

      elsif ? $mdata<secondary> {
        $server-status = SS-RSSecondary;
        $!client.add-servers([$mdata<primary>,]) if $mdata<primary>:exists;
      }

      elsif ? $mdata<arbiterOnly> {
        $server-status = SS-RSArbiter;
      }

      else {
        $server-status = SS-RSOther;
      }
    }

    else {
      $server-status = SS-Standalone;
      $is-master = ? $mdata<ismaster>;
    }

    ( $server-status, $is-master);
  }

  #-----------------------------------------------------------------------------
  method get-status ( --> Hash ) {

    $!rw-sem.reader( 's-status', { $!server-sts-data } );
  }

  #-----------------------------------------------------------------------------
  # Make a tap on the Supply. Use act() for this so we are sure that only this
  # code runs whithout any other parrallel threads.
  #
  method tap-monitor ( |c --> Tap ) {

    MongoDB::Server::Monitor.instance.get-supply.tap(|c);
  }

  #-----------------------------------------------------------------------------
  # Search in the array for a closed Socket.
  # By default authentiction is needed when user/password info is found in the
  # uri data. Monitor, however does not need this so therefore it is made
  # optional.
  method get-socket ( Bool :$authenticate = True --> MongoDB::Server::Socket ) {

#note "$*THREAD.id() Get sock, authenticate = $authenticate";

    # Get a free socket entry
    my MongoDB::Server::Socket $sock = $!rw-sem.writer( 's-select', {

        my MongoDB::Server::Socket $s;

        # Check all sockets first
        for ^(@!sockets.elems) -> $si {

          next unless @!sockets[$si].defined;

          if @!sockets[$si].check {
            @!sockets[$si] = Nil;
            trace-message("socket cleared");
          }
        }

        # Search for socket
        for ^(@!sockets.elems) -> $si {

          next unless @!sockets[$si].defined;

          if @!sockets[$si].thread-id == $*THREAD.id() {
            $s = @!sockets[$si];
            trace-message("socket found");
            last;
          }
        }

        # If none is found insert a new Socket in the array
        if not $s.defined {
          # search for an empty slot
          my Bool $slot-found = False;
          for ^(@!sockets.elems) -> $si {
            if not @!sockets[$si].defined {
              $s .= new(:server(self));
              @!sockets[$si] = $s;
              $slot-found = True;
            }
          }

          if not $slot-found {
            $s .= new(:server(self));
            @!sockets.push($s);
          }
        }

        $s;
      }
    );


    # Use return value to see if authentication is needed.
    my Bool $opened-before = $sock.open;

#TODO check must be made on autenticate flag only and determined from server
    # We can only authenticate when all 3 data are True and when the socket is
    # opened anew.
    if not $opened-before and $authenticate
       and (? $!uri-data<username> or ? $!uri-data<password>) {

      # get authentication mechanism
      my Str $auth-mechanism = $!credential.auth-mechanism;
      if not $auth-mechanism {
        my Int $max-version = $!rw-sem.reader(
          's-status', {$!server-sts-data<max-wire-version>}
        );
        $auth-mechanism = $max-version < 3 ?? 'MONGODB-CR' !! 'SCRAM-SHA-1';
        debug-message("Use mechanism '$auth-mechanism' decided by wire version($max-version)");
      }

      $!credential.auth-mechanism(:$auth-mechanism);


      given $auth-mechanism {

        # Default in version 3.*
        when 'SCRAM-SHA-1' {

          my MongoDB::Authenticate::Scram $client-object .= new(
            :$!client, :db-name($!uri-data<database>)
          );

          my Auth::SCRAM $sc .= new(
            :username($!uri-data<username>),
            :password($!uri-data<password>),
            :$client-object,
          );

          my $error = $sc.start-scram;
          fatal-message("Authentication fail: $error") if ? $error;
        }

        # Default in version 2.*
        when 'MONGODB-CR' {

        }

        when 'MONGODB-X509' {

        }

        # Kerberos
        when 'GSSAPI' {

        }

        # LDAP SASL
        when 'PLAIN' {

        }
      }
    }

    # Return a usable socket which is opened and authenticated upon if needed.
    $sock;
  }

  #-----------------------------------------------------------------------------
  multi method raw-query (
    Str:D $full-collection-name, BSON::Document:D $query,
    Int :$number-to-skip = 0, Int :$number-to-return = 1,
    Bool :$authenticate = True, Bool :$timed-query!
    --> List
  ) {

    my BSON::Document $doc;
    my Duration $rtt;

    ( $doc, $rtt) = MongoDB::Wire.new.timed-query(
      $full-collection-name, $query,
      :$number-to-skip, :number-to-return,
      :server(self), :$authenticate
    );

    ( $doc, $rtt);
  }


  multi method raw-query (
    Str:D $full-collection-name, BSON::Document:D $query,
    Int :$number-to-skip = 0, Int :$number-to-return = 1,
    Bool :$authenticate = True
    --> BSON::Document
  ) {
    debug-message("server directed query on collection $full-collection-name on server {self.name}");

    MongoDB::Wire.new.query(
      $full-collection-name, $query,
      :$number-to-skip, :number-to-return,
      :server(self), :$authenticate
    );
  }

  #-----------------------------------------------------------------------------
  method name ( --> Str ) {

    return [~] $!server-name // '-', ':', $!server-port // '-';
  }

  #-----------------------------------------------------------------------------
  # Forced cleanup
  method cleanup ( ) {

    # Its possible that server monitor is not defined when a server is
    # non existent or some other reason.
    $!server-tap.close if $!server-tap.defined;

    MongoDB::Server::Monitor.instance.unregister(self);

    # Clear all sockets
    $!rw-sem.writer( 's-select', {
        for ^(@!sockets.elems) -> $si {
          next unless @!sockets[$si].defined;
          @!sockets[$si].cleanup;
          @!sockets[$si] = Nil;
          trace-message("socket cleared");
        }
      }
    );

    $!client = Nil;
    $!uri-data = Nil;
    @!sockets = Nil;
    $!server-tap = Nil;
  }
}
