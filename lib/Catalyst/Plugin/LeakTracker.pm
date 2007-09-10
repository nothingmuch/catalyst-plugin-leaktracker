#!/usr/bin/perl

package Catalyst::Plugin::LeakTracker;

use strict;
use warnings;

use Devel::Events::Filter::Stamp;
use Devel::Events::Filter::RemoveFields;
use Devel::Events::Filter::Stringify;
use Devel::Events::Handler::Log::Memory;
use Devel::Events::Handler::Multiplex;

use Devel::Events::Generator::Objects;
use Devel::Events::Handler::ObjectTracker;

our $VERSION = 0.01;

use base qw/Catalyst::Plugin::C3 Class::Data::Inheritable/;

__PACKAGE__->mk_classdata($_) for qw/
    object_trackers
    devel_events_log
    devel_events_filters
    devel_events_multiplexer
    devel_events_generator
/;

sub setup {
    my ( $app, @args ) = @_;

    $app->object_trackers([]);

    my $log = $app->create_devel_events_log;

    # ensure the log doesn't leak
    my $filtered_log = $app->create_devel_events_log_filter($log);

    my $multiplexer = $app->create_devel_events_multiplexer();

    $multiplexer->add_handler($filtered_log);

    my $filters = $app->create_devel_events_filter_chain( $multiplexer );

    my $generator = $app->create_devel_events_object_event_generator( $filters );

    $app->devel_events_log($log);
    $app->devel_events_multiplexer($multiplexer);
    $app->devel_events_filters($filters);
    $app->devel_events_generator($generator);

    $app->NEXT::setup(@args);
}

# FIXME add events to prepare, dispatch and finalize

sub send_devel_event {
    my ( $self, @event ) = @_;
    $self->devel_events_filters->new_event( @event );
}

sub prepare {
    my ( $app, @args ) = @_;
    $app->send_devel_event( prepare => ( app => $app ) );
    $app->NEXT::prepare(@args);
}

sub dispatch {
    my ( $c, @args ) = @_;

    $c->send_devel_event( dispatch =>
        c       => $c,
        action  => $c->action,
        request => $c->request,
        uri     => $c->request->uri,
    );

    $c->NEXT::dispatch(@args);
}

sub execute {
    my ( $c, @args ) = @_;

    my ( $class, $action ) = @_;

    $c->send_devel_event( enter_action =>
        c      => $c,
        action => $action,
        class  => $class,
    );

    my $ret = $c->NEXT::execute(@args);

    $c->send_devel_event( leave_action =>
        c      => $c,
        action => $action,
        class  => $class,
    );

    return $ret;
}

sub finalize {
    my ( $c, @args ) = @_;

    $c->send_devel_event( finalize =>
        c        => $c,
        action   => $c->action,
        response => $c->response,
        body     => $c->response->body,
    );

    $c->NEXT::finalize(@args);
}

sub handle_request {
    my ( $app, @args ) = @_;

    $app->send_devel_event( request_begin => ( app => $app ) );

    my $tracker = $app->create_devel_events_object_tracker;
    push @{ $app->object_trackers }, $tracker;

    my $multiplexer = $app->devel_events_multiplexer;
    $multiplexer->add_handler( $tracker );

    my $generator = $app->devel_events_generator;
    $generator->enable;

    my $ret = $app->NEXT::handle_request(@args);

    $generator->disable;

    $multiplexer->remove_handler( $tracker );

    $app->send_devel_event( request_end => ( app => $app, status => $ret ) );

    return $ret;
}

sub create_devel_events_log {
    my ( $app, @args ) = @_;
    Devel::Events::Handler::Log::Memory->new();
}

sub create_devel_events_log_filter {
    my ( $app, @args ) = @_;

    @args = ( handler => @args ) if @args == 1;

    Devel::Events::Filter::Stringify->new(@args);
}

sub create_devel_events_multiplexer {
    my ( $app, @args ) = @_;
    Devel::Events::Handler::Multiplex->new();
}

sub create_devel_events_object_tracker {
    my ( $app, @args ) = @_;
    Devel::Events::Handler::ObjectTracker->new();
}

sub create_devel_events_object_event_generator {
    my ( $app, @args ) = @_;

    @args = ( handler => @args ) if @args == 1;

    Devel::Events::Generator::Objects->new(@args);
}

sub create_devel_events_filter_chain {
    my ( $app, @args ) = @_;

    @args = ( handler => @args ) if @args == 1;

    Devel::Events::Filter::Stamp->new(
        handler => Devel::Events::Filter::RemoveFields->new(
            fields => [qw/generator/],
            @args,
        ),
    );
}


__PACKAGE__;

__END__


