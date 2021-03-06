#!/usr/bin/env perl
###
# This script translates callbacks from graylog alerts to values in zabbix
###

use Mojo::Log;
use Mojolicious::Lite;

use JSON;
use Data::Dumper;
use IPC::Cmd 'run';

my $verbose    = $ENV{'MOJO_VERBOSE'} || 0;
my $config     = decode_json($ENV{'APP_CONFIG'}) || die "Invalid configuration";
my $zbx_sender = '/usr/bin/zabbix_sender';

my $logger = Mojo::Log->new;

helper zabbix_sender => sub {
  my $c          = shift;
  my $zbx_host   = shift;
  my $stream     = shift;
  my $grace      = shift;
  my $severity   = shift;
  my $zbx_server = $config->{'zabbix'}{'server'};

  my $timestamp  = time() + (($grace+1) * 60);
  my $command    = [
    $zbx_sender,
    '-z', $zbx_server,
    '-s', $zbx_host,
    '-k', "gzalertmon.grace[$severity,$stream]",
    '-o', $timestamp
  ];

  return (run(
    command => $command,
    verbose => $verbose,
    timeout => 5,
  ))[0];
};

under '/' => sub {
  my $c = shift;
  $c->res->headers->remove('Server');
};

post '/alert/:severity' => sub {
  my $c = shift;

  my $zbx_host;
  foreach my $graylog (@{$config->{'graylog'}}) {
    foreach my $ip (@{$graylog->{'ipaddress'}}) {
      $zbx_host = $graylog->{'hostname'} if $ip eq $c->tx->remote_address;
      last if $zbx_host;
    }
  }

  # Check whether host is configured
  unless ($zbx_host) {
    $logger->warn("Unknown zabbix-host: " . $c->tx->remote_address);
    $c->render(status => 403, json => {});
    return undef;
  }
  $logger->info("Alert for zabbix-host: $zbx_host [" . $c->tx->remote_address . "]");

  # Check for valid severity
  my $severity = $c->stash('severity');
  if ((! $severity) || ($severity !~ /^warning|critical$/)) {
    $logger->warn("Invalid severity: $severity");
    $c->render(status => 400, json => {});
    return undef;
  }

  # Check empty body
  my $body = $c->req->json;
  if ((! $body) || (! keys %$body)) {
    $logger->warn("Empty POST body");
    $c->render(status => 400, json => {});
    return undef;
  }

  $logger->info(Dumper $body) if $verbose;

  # Define stream
  my $stream_title = $body->{'stream'}{'title'};
  my $alert_grace  = $body->{'check_result'}{'triggered_condition'}{'parameters'}{'grace'} ||
                     $body->{'check_result'}{'triggered_condition'}{'grace'};

  unless (defined $alert_grace) {
    $logger->warn("No grace period found, defaulting to 1");
    $alert_grace = 1;
  }

  # Check for valid json
  unless ($stream_title) {
    $logger->warn("Missing stream title");
    $c->render(status => 400, json => {});
    return undef;
  }

  $logger->info("Alert for stream: '$stream_title', with grace: $alert_grace");

  if ($c->zabbix_sender($zbx_host, $stream_title, $alert_grace, $severity)) {
    $logger->info("Sent item value using zabbix_sender");
    $c->render(status => 201, json => {});
  } else {
    $logger->error("Problem executing zabbix_sender");
    $c->render(status => 503, json => {});
  }
};

app->start;
