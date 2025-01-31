package AmuseWikiFarm::Controller::Settings;
use Moose;
use namespace::autoclean;

use AmuseWikiFarm::Log::Contextual;

BEGIN { extends 'Catalyst::Controller'; }

use Try::Tiny;

=head1 NAME

AmuseWikiFarm::Controller::Settings - Catalyst Controller

=head1 DESCRIPTION

Catalyst Controller.

=head1 METHODS

=cut


=head2 index

=cut

sub settings :Chained('/site_user_required') :CaptureArgs(0) {
    my ($self, $c) = @_;
    $c->stash(breadcrumbs => [
                              {
                               uri => $c->uri_for_action('/user/site_config'),
                               label => $c->loc('Edit site configuration'),
                              },
                             ]);
    
}

sub list_custom_formats :Chained('settings') :PathPart('formats') :CaptureArgs(0) {
    my ($self, $c) = @_;
    unless ($c->check_any_user_role(qw/admin root/)) {
        $c->detach('/not_permitted');
        return;
    }
    push @{$c->stash->{breadcrumbs}}, {
                                       uri => $c->uri_for_action('/settings/formats'),
                                       label => $c->loc('Custom formats for [_1]',
                                                        $c->stash->{site}->canonical),
                                      };
}

sub formats :Chained('list_custom_formats') :PathPart('') :Args(0) {
    my ($self, $c) = @_;
    my @list;
    my $formats = $c->stash->{site}->custom_formats->sorted_by_priority;
    while (my $format = $formats->next) {
        my $id =  $format->custom_formats_id;
        push @list, {
                     id => $id,
                     code => $format->code,
                     edit_url => $c->uri_for_action('/settings/edit_format', [ $id ]),
                     deactivate_url => $c->uri_for_action('/settings/make_format_inactive', [ $id ]),
                     activate_url   => $c->uri_for_action('/settings/make_format_active', [ $id ]),
                     change_format_priority_url => $c->uri_for_action('/settings/change_format_priority', [ $id ]),
                     clone_url => $c->uri_for_action('/settings/clone_format', [ $id ]),
                     name => $format->format_name,
                     description => $format->format_description,
                     active => $format->active,
                     priority => $format->format_priority,
                     extension => $format->valid_alias || $format->extension,
                    };
    }
    # Dlog_debug { "Found these formats $_" } \@list;
    $c->stash(
              format_list => \@list,
              f_priority_values => [1..50],
              create_url => $c->uri_for_action('/settings/create_format'),
              page_title => $c->loc('Custom formats for [_1]', $c->stash->{site}->canonical),
             );
}

sub create_format :Chained('list_custom_formats') :PathPart('create') :Args(0) {
    my ($self, $c) = @_;
    my %params = %{ $c->request->body_parameters };
    if ($params{format_name} and length($params{format_name}) < 255) {
        my $priority = 1;
        if (my $last = $c->stash->{site}->custom_formats->sorted_by_priority_desc->first) {
            $priority = $last->format_priority + 1;
        }
        my $f = $c->stash->{site}->custom_formats->create({
                                                           format_name => "$params{format_name}",
                                                           format_priority => $priority,
                                                          });
        log_debug { "Created " . $f->format_name };
        log_debug { "Populating from site" };
        $f->create_format_code;
        $f->sync_from_site;
        $f->discard_changes;
        $c->response->redirect($c->uri_for_action('/settings/edit_format', [ $f->custom_formats_id ]));
        $c->flash(status_msg => $c->loc('Format successfully created'));
        return;
    }
    $c->response->redirect($c->uri_for_action('/settings/formats'));
}

sub get_format :Chained('list_custom_formats') :PathPart('edit') :CaptureArgs(1) {
    my ($self, $c, $id) = @_;
    log_debug { "Getting format id $id" };
    if ($id =~ m/([0-9]+)/) {
        if (my $format = $c->stash->{site}->custom_formats->find($id)) {
            $c->stash(edit_custom_format => $format);
            return;
        }
    }
    $c->detach('/not_found');
}

sub edit_format :Chained('get_format') :PathPart('') :Args(0) {
    my ($self, $c) = @_;
    my $format = $c->stash->{edit_custom_format};
    my %params = %{ $c->request->body_parameters };
    push @{$c->stash->{breadcrumbs}}, { uri => '#',
                                        label => $format->format_name };

    my $update = delete $params{update};
    my $reset =  delete $params{reset};

    if ($update || $reset) {
        Dlog_debug { "Params are $_" } \%params;
        my $result = $format->update_from_params(\%params);
        my @warnings = $format->enforce_standard_fields;
        if ($reset) {
            $format->sync_from_site;
        }
        if (@warnings) {
            $c->flash(error_msg => "Ignored changes: " . join(', ', @warnings));
        }
        elsif ($result->{error}) {
            $c->flash(error_msg => $result->{error});
        }
        else {
            $c->flash(status_msg => $c->loc('Format successfully updated'));
        }
        # user should be always here
        $c->stash->{site}->jobs->save_bb_cli_add($c->user->get('username'));
    }
    $c->stash(
              bb => $format->bookbuilder,
              page_title => $c->loc('Edit format [_1]', $format->format_name)
             );
}

sub make_format_inactive :Chained('get_format') :PathPart('inactive') :Args(0) {
    my ($self, $c) = @_;
    Dlog_debug { "setting active => 0 $_" } $c->request->body_parameters;
    my $cf = $c->stash->{edit_custom_format};
    if ($c->request->body_parameters->{go}) {
        $cf->update({ active => 0 });
        $cf->sync_site_format;
    }
    $c->response->redirect($c->uri_for_action('/settings/formats'));
}

sub make_format_active :Chained('get_format') :PathPart('active') :Args(0) {
    my ($self, $c) = @_;
    Dlog_debug { "setting active => 1 $_" } $c->request->body_parameters;
    my $cf = $c->stash->{edit_custom_format};
    if ($c->request->body_parameters->{go}) {
        $cf->update({ active => 1 });
        $cf->sync_site_format;
    }
    $c->response->redirect($c->uri_for_action('/settings/formats'));
}

sub change_format_priority :Chained('get_format') :PathPart('priority') :Args(0) {
    my ($self, $c) = @_;
    Dlog_debug { "setting priority => 1 $_" } $c->request->body_parameters;
    if (my $priority = $c->request->body_parameters->{priority}) {
        if ($priority =~ m/\A[1-9][0-9]*\z/) {
            $c->stash->{edit_custom_format}->update({ format_priority => $priority })
        }
    }
    $c->response->redirect($c->uri_for_action('/settings/formats'));
}

sub clone_format :Chained('get_format') :PathPart('clone') :Args(0) {
    my ($self, $c) = @_;
    Dlog_debug { "cloning CF" } $c->request->body_parameters;
    my $cf = $c->stash->{edit_custom_format};
    if ($c->request->body_parameters->{go}) {
        my %existing = map { $_->format_name => 1 } $cf->site->custom_formats->all;
        my $basename = $cf->format_name;
        $basename =~ s/ \([0-9]+\)$//;
        my $name = $basename;
        my $count = 0;
        Dlog_debug { "Existing CF $_" } \%existing;
        while ($existing{$name}) {
            $count++;
            $name = $basename . " ($count)";
        }
        my $copied = $cf->copy({
                                format_alias => undef,
                                format_code => undef,
                                format_name => $name,
                               });
        $copied->create_format_code;
        $cf->sync_site_format;
    }
    $c->response->redirect($c->uri_for_action('/settings/formats'));
}

sub list_categories :Chained('settings') :PathPart('categories') :CaptureArgs(0) {
    my ($self, $c) = @_;
    unless ($c->check_any_user_role(qw/admin root/)) {
        $c->detach('/not_permitted');
        return;
    }
}

sub categories :Chained('list_categories') :PathPart('') :Args(0) {
    my ($self, $c) = @_;
    my $site = $c->stash->{site};
    my $page_title = $c->loc('Category types for [_1]', $site->canonical);
    push @{$c->stash->{breadcrumbs}}, {
                                       uri => $c->uri_for_action('/settings/categories'),
                                       label => $page_title,
                                      };
    $c->stash(page_title => $page_title,
              site_category_types => [ $site->site_category_types->ordered->all ]
             );
}

sub edit_categories :Chained('list_categories') :PathPart('edit') :Args(0) {
    my ($self, $c) = @_;
    my $site = $c->stash->{site};
    my %params = %{ $c->request->body_parameters };
    try {
        if (my $changed = $site->edit_category_types_from_params(\%params)) {
            my $msg = $c->loc("Changes applied.");
            if ($changed > 1) {
                $msg .= " " . $c->loc("Please reindex the site.");
            }
            $c->flash(status_msg => $msg);
        }
    } catch {
        my $err = $_;
        log_error { $err };
        $c->flash(error_msg => "$err");
    };
    $c->response->redirect($c->uri_for_action('/settings/categories'));    
}

=encoding utf8

=head1 AUTHOR

Marco,,,

=head1 LICENSE

This library is free software. You can redistribute it and/or modify
it under the same terms as Perl itself.

=cut

__PACKAGE__->meta->make_immutable;

1;
