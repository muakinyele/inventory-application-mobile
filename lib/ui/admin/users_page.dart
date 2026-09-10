import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../core/design.dart';
import '../../core/formatters.dart';
import '../../core/palette.dart';
import '../../data/auth_api.dart';
import '../../models/auth_user.dart';
import '../../state/auth_controller.dart';
import '../auth/auth_scaffold.dart';
import '../widgets/empty_state.dart';
import '../widgets/page_header.dart';
import 'invite_user_sheet.dart';
import 'user_status_chip.dart';

/// The administrator's user list (§8).
///
/// Search, status and role filters, and paging — all server-side, because the
/// list is the one screen that has to stay correct on a workspace with more
/// users than fit in memory.
class UsersPage extends StatefulWidget {
  const UsersPage({super.key});

  @override
  State<UsersPage> createState() => _UsersPageState();
}

class _UsersPageState extends State<UsersPage> {
  static const _pageSize = 25;

  final _search = TextEditingController();
  Timer? _debounce;

  List<ManagedUser>? _users;
  int _total = 0;
  int _offset = 0;
  String? _status;
  String? _role;
  String? _error;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  void _onSearchChanged(String _) {
    // Debounced so typing does not fire a request per keystroke.
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      _offset = 0;
      _load();
    });
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final page = await context.read<AuthController>().api.listUsers(
        search: _search.text,
        status: _status,
        role: _role,
        limit: _pageSize,
        offset: _offset,
      );
      if (!mounted) return;
      setState(() {
        _users = page.users;
        _total = page.total;
        _error = null;
        _loading = false;
      });
    } on AuthApiException catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.message;
        _loading = false;
      });
    }
  }

  void _setFilter({
    String? status,
    String? role,
    bool clearStatus = false,
    bool clearRole = false,
  }) {
    setState(() {
      if (clearStatus) {
        _status = null;
      } else if (status != null) {
        _status = status;
      }
      if (clearRole) {
        _role = null;
      } else if (role != null) {
        _role = role;
      }
      _offset = 0;
    });
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final auth = context.watch<AuthController>();
    final canInvite = auth.can('users.create');

    return Scaffold(
      backgroundColor: p.plane,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                Insets.pageNarrow,
                Insets.xl,
                Insets.pageNarrow,
                0,
              ),
              child: PageHeader(
                title: 'Users',
                subtitle: _total == 1
                    ? '1 person has access'
                    : '$_total people have access',
                actions: [
                  if (canInvite)
                    FilledButton.icon(
                      onPressed: () async {
                        final invited = await showInviteUserSheet(context);
                        if (invited) {
                          _offset = 0;
                          await _load();
                        }
                      },
                      icon: const Icon(
                        Icons.person_add_alt_1_rounded,
                        size: 18,
                      ),
                      label: const Text('Invite'),
                    ),
                ],
              ),
            ),
            const SizedBox(height: Insets.lg),

            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: Insets.pageNarrow,
              ),
              child: Column(
                children: [
                  TextField(
                    controller: _search,
                    onChanged: _onSearchChanged,
                    decoration: InputDecoration(
                      hintText: 'Search by name or email',
                      prefixIcon: const Icon(Icons.search_rounded),
                      suffixIcon: _search.text.isEmpty
                          ? null
                          : IconButton(
                              icon: const Icon(Icons.clear_rounded),
                              tooltip: 'Clear search',
                              onPressed: () {
                                _search.clear();
                                _offset = 0;
                                _load();
                              },
                            ),
                    ),
                  ),
                  const SizedBox(height: Insets.md),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        _FilterChip(
                          label: 'Everyone',
                          selected: _status == null && _role == null,
                          onTap: () =>
                              _setFilter(clearStatus: true, clearRole: true),
                        ),
                        _FilterChip(
                          label: 'Active',
                          selected: _status == 'active',
                          onTap: () => _status == 'active'
                              ? _setFilter(clearStatus: true)
                              : _setFilter(status: 'active'),
                        ),
                        _FilterChip(
                          label: 'Pending',
                          selected: _status == 'pending',
                          onTap: () => _status == 'pending'
                              ? _setFilter(clearStatus: true)
                              : _setFilter(status: 'pending'),
                        ),
                        _FilterChip(
                          label: 'Disabled',
                          selected: _status == 'disabled',
                          onTap: () => _status == 'disabled'
                              ? _setFilter(clearStatus: true)
                              : _setFilter(status: 'disabled'),
                        ),
                        _FilterChip(
                          label: 'Administrators',
                          selected: _role == 'administrator',
                          onTap: () => _role == 'administrator'
                              ? _setFilter(clearRole: true)
                              : _setFilter(role: 'administrator'),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: Insets.lg),

            Expanded(child: _body(context)),
          ],
        ),
      ),
    );
  }

  Widget _body(BuildContext context) {
    final p = context.palette;

    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: Insets.pageNarrow),
        child: Column(
          children: [
            AuthNotice(message: _error!),
            const SizedBox(height: Insets.lg),
            OutlinedButton(onPressed: _load, child: const Text('Try again')),
          ],
        ),
      );
    }

    if (_users == null) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_users!.isEmpty) {
      return EmptyState(
        icon: Icons.person_search_rounded,
        title: _search.text.isEmpty && _status == null && _role == null
            ? 'No users yet'
            : 'Nobody matches those filters',
        body: _search.text.isEmpty && _status == null && _role == null
            ? 'Invite a colleague to get started.'
            : 'Try a different search or clear the filters.',
      );
    }

    final lastPage = _offset + _pageSize >= _total;

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(
        Insets.pageNarrow,
        0,
        Insets.pageNarrow,
        Insets.section,
      ),
      itemCount: _users!.length + 1,
      separatorBuilder: (_, _) => const SizedBox(height: Insets.sm),
      itemBuilder: (context, index) {
        if (index == _users!.length) {
          if (_total <= _pageSize) return const SizedBox.shrink();
          return Padding(
            padding: const EdgeInsets.only(top: Insets.lg),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                TextButton.icon(
                  onPressed: _offset == 0 || _loading
                      ? null
                      : () {
                          setState(() => _offset -= _pageSize);
                          _load();
                        },
                  icon: const Icon(Icons.chevron_left_rounded),
                  label: const Text('Previous'),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: Insets.md),
                  child: Text(
                    '${_offset + 1}–${_offset + _users!.length} of $_total',
                    style: TextStyle(color: p.inkMuted, fontSize: 13),
                  ),
                ),
                TextButton.icon(
                  onPressed: lastPage || _loading
                      ? null
                      : () {
                          setState(() => _offset += _pageSize);
                          _load();
                        },
                  icon: const Icon(Icons.chevron_right_rounded),
                  label: const Text('Next'),
                ),
              ],
            ),
          );
        }

        return _UserTile(
          user: _users![index],
          onTap: () async {
            await context.push('/users/${_users![index].id}');
            if (mounted) await _load();
          },
        );
      },
    );
  }
}

class _FilterChip extends StatelessWidget {
  const _FilterChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Padding(
      padding: const EdgeInsets.only(right: Insets.sm),
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: Insets.md,
            vertical: Insets.sm,
          ),
          decoration: BoxDecoration(
            color: selected ? p.accent : p.surface,
            borderRadius: BorderRadius.circular(Radii.pill),
            border: Border.all(color: selected ? p.accent : p.line),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: selected ? p.accentInk : p.inkSecondary,
              fontWeight: FontWeight.w600,
              fontSize: 13,
            ),
          ),
        ),
      ),
    );
  }
}

class _UserTile extends StatelessWidget {
  const _UserTile({required this.user, required this.onTap});

  final ManagedUser user;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;

    return Material(
      color: p.surface,
      borderRadius: BorderRadius.circular(Radii.card),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(Radii.card),
        child: Container(
          padding: const EdgeInsets.all(Insets.lg),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(Radii.card),
            border: Border.all(color: p.line),
          ),
          child: Row(
            children: [
              Container(
                width: 42,
                height: 42,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: p.accentWash,
                  borderRadius: BorderRadius.circular(Radii.pill),
                ),
                child: Text(
                  initials(user.name.isEmpty ? user.email : user.name),
                  style: TextStyle(
                    color: p.accent,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: Insets.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      user.name.isEmpty ? user.email : user.name,
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: p.ink,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      user.email,
                      style: TextStyle(color: p.inkMuted, fontSize: 13),
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: Insets.sm),
                    Wrap(
                      spacing: Insets.sm,
                      runSpacing: Insets.xs,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        UserStatusChip(user: user),
                        if (user.roleNames.isNotEmpty)
                          Text(
                            user.roleNames.join(', '),
                            style: TextStyle(
                              color: p.inkSecondary,
                              fontSize: 12,
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: Insets.sm),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Icon(Icons.chevron_right_rounded, color: p.inkMuted),
                  if (user.lastLoginAt != null)
                    Text(
                      relativeTime(user.lastLoginAt!),
                      style: TextStyle(color: p.inkMuted, fontSize: 11),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
