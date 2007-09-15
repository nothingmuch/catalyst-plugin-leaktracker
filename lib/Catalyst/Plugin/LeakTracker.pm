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
    object_tracker_hash
    devel_events_log
    devel_events_filters
    devel_events_multiplexer
    devel_events_generator
/;

sub setup {
    my ( $app, @args ) = @_;

    $app->object_trackers([]);
    $app->object_tracker_hash({});

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

    local $@;

    $c->send_devel_event( dispatch =>
        c           => $c,
        action      => $c->action,
        action_name => eval { $c->action->reverse },
        controller  => eval { $c->action->class },
        request     => $c->request,
        uri_object  => $c->request->uri,
        uri         => ($c->request->uri . ""), # Stringify will avoid overloading
    );

    $c->NEXT::dispatch(@args);
}

sub execute {
    my ( $c, @args ) = @_;

    my ( $class, $action ) = @args;

    $c->send_devel_event( enter_action =>
        c           => $c,
        action      => $action,
        action_name => $action->reverse,
        class       => $class,
        arguments   => [@{$c->request->args}],
    );

    my $ret = $c->NEXT::execute(@args);

    $c->send_devel_event( leave_action =>
        c           => $c,
        action      => $action,
        action_name => $action->reverse,
        class       => $class,
    );

    return $ret;
}

sub finalize {
    my ( $c, @args ) = @_;

    $c->send_devel_event( finalize =>
        c        => $c,
        action   => $c->action,
        response => $c->response,
    );

    $c->NEXT::finalize(@args);
}

my $i;

sub handle_request {
    my ( $app, @args ) = @_;

    my $req_id = ++$i;

    $app->send_devel_event( request_begin => ( app => $app, request_id => $req_id ) );

    my $tracker = $app->create_devel_events_object_tracker;

    push @{ $app->object_trackers }, $tracker;
    $app->object_tracker_hash->{$req_id} = $tracker;

    my $multiplexer = $app->devel_events_multiplexer;
    $multiplexer->add_handler( $tracker );

    my $generator = $app->devel_events_generator;
    $generator->enable;

    my $ret = $app->NEXT::handle_request(@args);

    $generator->disable;

    $multiplexer->remove_handler( $tracker );

    $app->send_devel_event( request_end => ( app => $app, status => $ret, request_id => $req_id ) );

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

sub get_all_request_ids {
    my $c = shift;
    map { my ( $type, %req ) = @$_; $req{request_id} } $c->get_all_request_begin_events;
}

sub get_all_request_begin_events {
    my $c = shift;
    $c->devel_events_log->grep("request_begin");
}

sub get_request_events {
    my ( $c, $request_id ) = @_;
    $c->devel_events_log->limit( from => { request_id => $request_id }, to => "request_end" );
}

sub get_event_by_id {
    my ( $c, $event_id ) = @_;

    if ( my $event = ( $c->devel_events_log->grep({ id => $event_id }) )[0] ) {
        return @$event;
    } else {
        return;
    }
}

sub generate_stack_for_event {
    my ( $c, $request_id, $event_id ) = @_;

    my @events = $c->devel_events_log->limit( from => { request_id => $request_id }, to => { id => $event_id } );

    my @stack;
    foreach my $event ( @events ) {
        my ( $type, %data ) = @$event;

        if ( $type eq 'enter_action' ) {
            push @stack, \%data;
        } elsif ( $type eq 'leave_action' ) {
            pop @stack;
        }
    }

    return @stack;
}

sub get_object_tracker_by_id {
    my ( $c, $request_id ) = @_;
    $c->object_tracker_hash->{$request_id};
}

sub get_object_entry_by_id {
    my ( $c, $request_id, $id ) = @_;

    if ( my $tracker = $c->get_object_tracker_by_id($request_id) ) {
        my $live_objects = $tracker->live_objects;

        foreach my $obj ( values %$live_objects ) {
            return $obj if $obj->{id} == $id;
        }
    }

    return;
}

sub get_object_by_event_id {
    my ( $c, $request_id, $id ) = @_;

    if ( my $entry = $c->get_object_entry_by_id( $request_id, $id ) ) {
        return $entry->{object};
    } else {
        return;
    }
}

__PACKAGE__;

__END__

=pod

=head1 NAME

Catalyst::Plugin::LeakTracker - Use L<Devel::Events::Objects> to track object
leaks in the Catalyst request cycle.

=head1 SYNOPSIS

    package MyApp;

    use Catalyst qw/
        LeakTracker
    /;

    # ...

    sub foo : Local {
        my ( $self, $c ) = @_;

        $c->object_trackers
    }

=head1 DESCRIPTION

This plugin will use L<Devel::Events::Objects> and
L<Devel::Events::Handler::Log::Memory> to keep track of objects created in
every request. It will also generate events corresponding to the request flow
and action execution to facilitate generating stack dumps and more debugging
information.

You probably just want to use L<Catalyst::Controller::LeakTracker> to get leak
reports though.


=cut
