import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/timezone.dart' as tz;
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:permission_handler/permission_handler.dart';

final FlutterLocalNotificationsPlugin notificationsPlugin =
    FlutterLocalNotificationsPlugin();

const String kSelectedTeamsKey = 'selected_teams';
const String kReminderOffsetKey = 'reminder_offset_minutes';
const int kDefaultOffsetMinutes = 30;

Future<int> scheduleAllReminders(List<Team> teams, int offsetMinutes) async {
  int notifId = 0;
  await notificationsPlugin.cancelAll();
  int scheduled = 0;
  for (final team in teams) {
    try {
      final resp = await http.get(Uri.parse(
          'https://www.thesportsdb.com/api/v1/json/3/eventsnext.php?id=${team.id}'));
      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body);
        final events = data['events'] as List<dynamic>? ?? [];
        for (final e in events) {
          final fixture = Fixture.fromJson(e);
          if (fixture.dateTimeUtc == null) continue;
          final matchTimeUtc =
              tz.TZDateTime.from(fixture.dateTimeUtc!, tz.getLocation('UTC'));

          final offsets = <int>{offsetMinutes, 1440}; // custom + 1 day before
          for (final mins in offsets) {
            final reminderTime = matchTimeUtc.subtract(Duration(minutes: mins));
            if (reminderTime.isAfter(tz.TZDateTime.now(tz.local))) {
              final label = mins == 1440 ? 'tomorrow' : 'in $mins minutes';
              await notificationsPlugin.zonedSchedule(
                notifId++,
                '${fixture.homeTeam} vs ${fixture.awayTeam}',
                '${fixture.league} starts $label',
                tz.TZDateTime.from(reminderTime, tz.local),
                const NotificationDetails(
                  android: AndroidNotificationDetails(
                      'match_reminders', 'Match Reminders',
                      importance: Importance.high, priority: Priority.high),
                ),
                androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
                uiLocalNotificationDateInterpretation:
                    UILocalNotificationDateInterpretation.absoluteTime,
              );
              scheduled++;
            }
          }
        }
      }
    } catch (_) {}
  }
  return scheduled;
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MatchReminderApp());
}

class MatchReminderApp extends StatelessWidget {
  const MatchReminderApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Match Reminder',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF3949AB)),
        scaffoldBackgroundColor: const Color(0xFFF6F6FA),
        cardTheme: CardThemeData(
          elevation: 1.5,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          margin: EdgeInsets.zero,
        ),
        appBarTheme: const AppBarTheme(
          centerTitle: false,
          elevation: 0,
        ),
      ),
      home: const HomePage(),
    );
  }
}

// ---------- Models ----------
// ---------- Badge field fallback ----------
// TheSportsDB has returned the crest under different key names over the
// years depending on the endpoint. Try them in order and use the first
// non-empty value.
String pickBadge(Map<String, dynamic> j) {
  for (final key in [
    'strTeamBadge',
    'strBadge',
    'strTeamLogo',
    'strLogo',
    'strTeamBadgeSquare',
  ]) {
    final v = j[key];
    if (v != null && v.toString().trim().isNotEmpty) {
      return v.toString();
    }
  }
  return '';
}

class Team {
  final String id;
  final String name;
  final String league;
  final String badge;
  final String idLeague;
  Team(
      {required this.id,
      required this.name,
      required this.league,
      required this.badge,
      this.idLeague = ''});
  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'league': league,
        'badge': badge,
        'idLeague': idLeague
      };
  factory Team.fromJson(Map<String, dynamic> j) => Team(
      id: j['id'],
      name: j['name'],
      league: j['league'],
      badge: j['badge'],
      idLeague: j['idLeague'] ?? '');
}

class Fixture {
  final String homeTeam;
  final String awayTeam;
  final String league;
  final DateTime? dateTimeUtc;
  final bool finished;
  final int? homeScore;
  final int? awayScore;

  Fixture({
    required this.homeTeam,
    required this.awayTeam,
    required this.league,
    required this.dateTimeUtc,
    this.finished = false,
    this.homeScore,
    this.awayScore,
  });

  factory Fixture.fromJson(Map<String, dynamic> e) {
    final dateStr = e['dateEvent'];
    final timeStr = e['strTime'];
    DateTime? dt;
    if (dateStr != null && timeStr != null && timeStr != '') {
      dt = DateTime.tryParse('${dateStr}T$timeStr');
    } else if (dateStr != null) {
      dt = DateTime.tryParse('${dateStr}T12:00:00');
    }
    int? hs = int.tryParse('${e['intHomeScore'] ?? ''}');
    int? as_ = int.tryParse('${e['intAwayScore'] ?? ''}');
    return Fixture(
      homeTeam: e['strHomeTeam'] ?? '',
      awayTeam: e['strAwayTeam'] ?? '',
      league: e['strLeague'] ?? '',
      dateTimeUtc: dt,
      finished: hs != null && as_ != null,
      homeScore: hs,
      awayScore: as_,
    );
  }
}

// ---------- Team colors ----------
Color colorForTeam(String name) {
  final n = name.toLowerCase();
  if (n.contains('manchester united') || n.contains('man utd')) {
    return const Color(0xFFDA291C);
  }
  if (n.contains('chelsea')) return const Color(0xFF034694);
  if (n.contains('real madrid')) return const Color(0xFF1B3F8B);
  if (n.contains('ac milan') || n.contains('milan')) {
    return const Color(0xFFFB090B);
  }
  final hash = name.codeUnits.fold(0, (a, b) => a + b);
  final hue = (hash * 37) % 360;
  return HSLColor.fromAHSL(1, hue.toDouble(), 0.55, 0.45).toColor();
}

String countdownText(DateTime? utc) {
  if (utc == null) return '';
  final now = DateTime.now().toUtc();
  final diff = utc.difference(now);
  if (diff.isNegative) return 'Started';
  if (diff.inDays >= 1) return 'in ${diff.inDays} day${diff.inDays > 1 ? 's' : ''}';
  if (diff.inHours >= 1) return 'in ${diff.inHours} hr${diff.inHours > 1 ? 's' : ''}';
  return 'in ${diff.inMinutes} min';
}

String formatDateTime(DateTime? utc) {
  if (utc == null) return 'Date TBD';
  final local = utc.toLocal();
  final months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
  ];
  final h = local.hour % 12 == 0 ? 12 : local.hour % 12;
  final ampm = local.hour >= 12 ? 'PM' : 'AM';
  final min = local.minute.toString().padLeft(2, '0');
  return '${local.day} ${months[local.month - 1]}, $h:$min $ampm';
}

// ---------- Home Page ----------
class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with SingleTickerProviderStateMixin {
  List<Team> selectedTeams = [];
  List<Fixture> allUpcoming = [];
  bool loading = true;
  bool syncing = false;
  int reminderOffset = kDefaultOffsetMinutes;
  late TabController tabController;

  @override
  void initState() {
    super.initState();
    tabController = TabController(length: 2, vsync: this);
    _init();
  }

  Future<void> _init() async {
    tzdata.initializeTimeZones();
    await _initNotifications();
    await Permission.notification.request();
    final prefs = await SharedPreferences.getInstance();
    reminderOffset = prefs.getInt(kReminderOffsetKey) ?? kDefaultOffsetMinutes;
    await _loadTeams();
    setState(() => loading = false);
    if (selectedTeams.isNotEmpty) {
      await _syncMatches(silent: true);
    }
  }

  Future<void> _initNotifications() async {
    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    const initSettings = InitializationSettings(android: androidInit);
    await notificationsPlugin.initialize(initSettings);
    const channel = AndroidNotificationChannel(
      'match_reminders',
      'Match Reminders',
      description: 'Reminders for upcoming matches',
      importance: Importance.high,
    );
    await notificationsPlugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(channel);
  }

  Future<void> _loadTeams() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(kSelectedTeamsKey) ?? [];
    setState(() {
      selectedTeams = raw.map((s) => Team.fromJson(jsonDecode(s))).toList();
    });
    await _backfillMissingBadges();
  }

  // Teams saved before the badge-field fix may have an empty badge URL.
  // Re-fetch their crest once so old entries pick it up automatically.
  Future<void> _backfillMissingBadges() async {
    bool changed = false;
    for (int i = 0; i < selectedTeams.length; i++) {
      final t = selectedTeams[i];
      if (t.badge.isNotEmpty) continue;
      try {
        final resp = await http.get(Uri.parse(
            'https://www.thesportsdb.com/api/v1/json/3/lookupteam.php?id=${t.id}'));
        if (resp.statusCode == 200) {
          final data = jsonDecode(resp.body);
          final teams = data['teams'] as List<dynamic>?;
          if (teams != null && teams.isNotEmpty) {
            final badge = pickBadge(teams[0]);
            final idLeague = t.idLeague.isNotEmpty
                ? t.idLeague
                : (teams[0]['idLeague']?.toString() ?? '');
            if (badge.isNotEmpty || idLeague.isNotEmpty) {
              selectedTeams[i] = Team(
                  id: t.id,
                  name: t.name,
                  league: t.league,
                  badge: badge,
                  idLeague: idLeague);
              changed = true;
            }
          }
        }
      } catch (_) {}
    }
    if (changed) {
      setState(() {});
      await _saveTeams();
    }
  }

  Future<void> _saveTeams() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(kSelectedTeamsKey,
        selectedTeams.map((t) => jsonEncode(t.toJson())).toList());
  }

  Future<void> _addTeam() async {
    final result = await Navigator.push<Team>(
        context, MaterialPageRoute(builder: (_) => const SearchTeamPage()));
    if (result != null && !selectedTeams.any((t) => t.id == result.id)) {
      setState(() => selectedTeams.add(result));
      await _saveTeams();
      await _syncMatches();
    }
  }

  Future<void> _removeTeam(Team t) async {
    setState(() => selectedTeams.removeWhere((x) => x.id == t.id));
    await _saveTeams();
    await _syncMatches(silent: true);
  }

  Future<void> _changeOffset(int minutes) async {
    setState(() => reminderOffset = minutes);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(kReminderOffsetKey, minutes);
    await _syncMatches();
  }

  Future<void> _syncMatches({bool silent = false}) async {
    if (selectedTeams.isEmpty) return;
    setState(() => syncing = true);

    final scheduled = await scheduleAllReminders(selectedTeams, reminderOffset);

    // Build combined upcoming list for the "All Matches" tab
    List<Fixture> combined = [];
    for (final team in selectedTeams) {
      try {
        final resp = await http.get(Uri.parse(
            'https://www.thesportsdb.com/api/v1/json/3/eventsnext.php?id=${team.id}'));
        if (resp.statusCode == 200) {
          final data = jsonDecode(resp.body);
          final events = data['events'] as List<dynamic>? ?? [];
          combined.addAll(events.map((e) => Fixture.fromJson(e)));
        }
      } catch (_) {}
    }
    combined.sort((a, b) {
      if (a.dateTimeUtc == null) return 1;
      if (b.dateTimeUtc == null) return -1;
      return a.dateTimeUtc!.compareTo(b.dateTimeUtc!);
    });

    setState(() {
      allUpcoming = combined;
      syncing = false;
    });

    if (!silent && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Done — $scheduled reminders updated'),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Match Reminder'),
        bottom: TabBar(
          controller: tabController,
          tabs: const [
            Tab(text: 'My Teams'),
            Tab(text: 'All Matches'),
          ],
        ),
        actions: [
          PopupMenuButton<int>(
            icon: const Icon(Icons.notifications_active_outlined),
            tooltip: 'Reminder time',
            onSelected: _changeOffset,
            itemBuilder: (context) => [
              CheckedPopupMenuItem(
                  value: 30,
                  checked: reminderOffset == 30,
                  child: const Text('30 minutes before')),
              CheckedPopupMenuItem(
                  value: 60,
                  checked: reminderOffset == 60,
                  child: const Text('1 hour before')),
              CheckedPopupMenuItem(
                  value: 180,
                  checked: reminderOffset == 180,
                  child: const Text('3 hours before')),
              CheckedPopupMenuItem(
                  value: 1440,
                  checked: reminderOffset == 1440,
                  child: const Text('1 day before')),
            ],
          ),
        ],
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : TabBarView(
              controller: tabController,
              children: [
                _buildTeamsTab(),
                _buildAllMatchesTab(),
              ],
            ),
      floatingActionButton: AnimatedBuilder(
        animation: tabController,
        builder: (context, _) {
          if (tabController.index != 0) return const SizedBox.shrink();
          return FloatingActionButton(
            onPressed: _addTeam,
            child: const Icon(Icons.add),
          );
        },
      ),
    );
  }

  Widget _buildTeamsTab() {
    return RefreshIndicator(
      onRefresh: _syncMatches,
      child: Column(
        children: [
          if (syncing)
            const LinearProgressIndicator(minHeight: 2),
          Expanded(
            child: selectedTeams.isEmpty
                ? ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    children: const [
                      SizedBox(height: 120),
                      Center(
                          child: Text(
                              'No teams yet.\nTap "+" to add your favorite teams.',
                              textAlign: TextAlign.center)),
                    ],
                  )
                : ListView.builder(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.all(12),
                    itemCount: selectedTeams.length,
                    itemBuilder: (context, i) {
                      final t = selectedTeams[i];
                      final color = colorForTeam(t.name);
                      return Container(
                        margin: const EdgeInsets.only(bottom: 12),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(18),
                          boxShadow: [
                            BoxShadow(
                              color: color.withOpacity(0.25),
                              blurRadius: 10,
                              offset: const Offset(0, 4),
                            ),
                          ],
                        ),
                        child: Material(
                          color: Colors.transparent,
                          borderRadius: BorderRadius.circular(18),
                          clipBehavior: Clip.antiAlias,
                          child: InkWell(
                            onTap: () => Navigator.push(
                                context,
                                MaterialPageRoute(
                                    builder: (_) =>
                                        TeamFixturesPage(team: t))),
                            child: Container(
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  begin: Alignment.centerLeft,
                                  end: Alignment.centerRight,
                                  colors: [
                                    color.withOpacity(0.14),
                                    color.withOpacity(0.02),
                                  ],
                                ),
                              ),
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 14, vertical: 12),
                              child: Row(
                                children: [
                                  Container(
                                    width: 56,
                                    height: 56,
                                    decoration: BoxDecoration(
                                      color: Colors.white,
                                      shape: BoxShape.circle,
                                      border: Border.all(
                                          color: color.withOpacity(0.4),
                                          width: 2),
                                      boxShadow: [
                                        BoxShadow(
                                            color: color.withOpacity(0.2),
                                            blurRadius: 6)
                                      ],
                                    ),
                                    child: t.badge.isNotEmpty
                                        ? ClipOval(
                                            child: Padding(
                                              padding:
                                                  const EdgeInsets.all(6),
                                              child: Image.network(t.badge,
                                                  errorBuilder:
                                                      (_, __, ___) => Icon(
                                                          Icons.sports_soccer,
                                                          color: color)),
                                            ),
                                          )
                                        : Icon(Icons.sports_soccer,
                                            color: color),
                                  ),
                                  const SizedBox(width: 16),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(t.name,
                                            style: const TextStyle(
                                                fontWeight: FontWeight.bold,
                                                fontSize: 17)),
                                        const SizedBox(height: 2),
                                        Text(t.league,
                                            style: TextStyle(
                                                color: Colors.grey.shade600,
                                                fontSize: 13)),
                                      ],
                                    ),
                                  ),
                                  Icon(Icons.chevron_right, color: color),
                                  IconButton(
                                      icon: const Icon(Icons.delete_outline,
                                          color: Colors.redAccent),
                                      onPressed: () => _removeTeam(t)),
                                ],
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildAllMatchesTab() {
    return RefreshIndicator(
      onRefresh: _syncMatches,
      child: allUpcoming.isEmpty
          ? ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: const [
                SizedBox(height: 120),
                Center(
                    child: Text(
                        'No upcoming matches yet.\nAdd teams or pull down to refresh.',
                        textAlign: TextAlign.center)),
              ],
            )
          : ListView.builder(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.all(12),
              itemCount: allUpcoming.length,
              itemBuilder: (context, i) {
                final f = allUpcoming[i];
                final color = colorForTeam(f.homeTeam);
                return Card(
                  margin: const EdgeInsets.only(bottom: 10),
                  child: ListTile(
                    leading: CircleAvatar(
                      backgroundColor: color.withOpacity(0.15),
                      child: Icon(Icons.sports_soccer, color: color),
                    ),
                    title: Text('${f.homeTeam} vs ${f.awayTeam}',
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: Text('${f.league}\n${formatDateTime(f.dateTimeUtc)}'),
                    isThreeLine: true,
                    trailing: Text(
                      countdownText(f.dateTimeUtc),
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.primary,
                          fontWeight: FontWeight.w600),
                    ),
                  ),
                );
              },
            ),
    );
  }
}

// ---------- Team fixtures (upcoming + results) ----------
class TeamFixturesPage extends StatefulWidget {
  final Team team;
  const TeamFixturesPage({super.key, required this.team});
  @override
  State<TeamFixturesPage> createState() => _TeamFixturesPageState();
}

class StandingRow {
  final String rank;
  final String teamName;
  final String badge;
  final String played;
  final String win;
  final String draw;
  final String loss;
  final String points;
  StandingRow({
    required this.rank,
    required this.teamName,
    required this.badge,
    required this.played,
    required this.win,
    required this.draw,
    required this.loss,
    required this.points,
  });
  factory StandingRow.fromJson(Map<String, dynamic> j) => StandingRow(
        rank: '${j['intRank'] ?? ''}',
        teamName: j['strTeam'] ?? '',
        badge: pickBadge(j),
        played: '${j['intPlayed'] ?? ''}',
        win: '${j['intWin'] ?? ''}',
        draw: '${j['intDraw'] ?? ''}',
        loss: '${j['intLoss'] ?? ''}',
        points: '${j['intPoints'] ?? ''}',
      );
}

class PlayerInfo {
  final String name;
  final String position;
  final String photo;
  PlayerInfo({required this.name, required this.position, required this.photo});
  factory PlayerInfo.fromJson(Map<String, dynamic> j) => PlayerInfo(
        name: j['strPlayer'] ?? '',
        position: j['strPosition'] ?? '',
        photo: (j['strCutout'] ?? j['strThumb'] ?? '') as String,
      );
}

class _TeamFixturesPageState extends State<TeamFixturesPage>
    with SingleTickerProviderStateMixin {
  late TabController tabController;
  List<Fixture> upcoming = [];
  List<Fixture> results = [];
  List<StandingRow> standings = [];
  List<PlayerInfo> squad = [];
  bool loading = true;

  @override
  void initState() {
    super.initState();
    tabController = TabController(length: 4, vsync: this);
    _load();
  }

  Future<void> _load() async {
    setState(() => loading = true);
    try {
      final nextResp = await http.get(Uri.parse(
          'https://www.thesportsdb.com/api/v1/json/3/eventsnext.php?id=${widget.team.id}'));
      final lastResp = await http.get(Uri.parse(
          'https://www.thesportsdb.com/api/v1/json/3/eventslast.php?id=${widget.team.id}'));

      List<Fixture> up = [];
      List<Fixture> res = [];
      if (nextResp.statusCode == 200) {
        final data = jsonDecode(nextResp.body);
        final events = data['events'] as List<dynamic>? ?? [];
        up = events.map((e) => Fixture.fromJson(e)).toList();
      }
      if (lastResp.statusCode == 200) {
        final data = jsonDecode(lastResp.body);
        final events = data['results'] as List<dynamic>? ?? [];
        res = events.map((e) => Fixture.fromJson(e)).toList();
      }

      List<StandingRow> table = [];
      if (widget.team.idLeague.isNotEmpty) {
        try {
          final tableResp = await http.get(Uri.parse(
              'https://www.thesportsdb.com/api/v1/json/3/lookuptable.php?l=${widget.team.idLeague}'));
          if (tableResp.statusCode == 200) {
            final data = jsonDecode(tableResp.body);
            final rows = data['table'] as List<dynamic>? ?? [];
            table = rows.map((r) => StandingRow.fromJson(r)).toList();
          }
        } catch (_) {}
      }

      List<PlayerInfo> players = [];
      try {
        final playersResp = await http.get(Uri.parse(
            'https://www.thesportsdb.com/api/v1/json/3/lookup_all_players.php?id=${widget.team.id}'));
        if (playersResp.statusCode == 200) {
          final data = jsonDecode(playersResp.body);
          final list = data['player'] as List<dynamic>? ?? [];
          players = list.map((p) => PlayerInfo.fromJson(p)).toList();
        }
      } catch (_) {}

      setState(() {
        upcoming = up;
        results = res;
        standings = table;
        squad = players;
      });
    } catch (_) {} finally {
      setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final color = colorForTeam(widget.team.name);
    return Scaffold(
      body: NestedScrollView(
        headerSliverBuilder: (context, innerBoxIsScrolled) => [
          SliverAppBar(
            pinned: true,
            expandedHeight: 150,
            backgroundColor: color,
            flexibleSpace: FlexibleSpaceBar(
              titlePadding: const EdgeInsets.only(left: 56, bottom: 14),
              title: Text(widget.team.name,
                  style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: Colors.white)),
              background: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [color, color.withOpacity(0.65)],
                  ),
                ),
                child: Center(
                  child: widget.team.badge.isNotEmpty
                      ? Padding(
                          padding: const EdgeInsets.only(top: 24, bottom: 34),
                          child: Image.network(widget.team.badge,
                              height: 64,
                              errorBuilder: (_, __, ___) => const Icon(
                                  Icons.sports_soccer,
                                  size: 56,
                                  color: Colors.white)),
                        )
                      : const SizedBox(),
                ),
              ),
            ),
            bottom: TabBar(
              controller: tabController,
              indicatorColor: Colors.white,
              labelColor: Colors.white,
              unselectedLabelColor: Colors.white70,
              tabs: const [
                Tab(text: 'Upcoming'),
                Tab(text: 'Results'),
                Tab(text: 'Table'),
                Tab(text: 'Squad'),
              ],
            ),
          ),
        ],
        body: loading
            ? const Center(child: CircularProgressIndicator())
            : RefreshIndicator(
                onRefresh: _load,
                child: TabBarView(
                  controller: tabController,
                  children: [
                    _fixtureList(upcoming, color, showCountdown: true),
                    _fixtureList(results, color, showScore: true),
                    _standingsList(color),
                    _squadList(color),
                  ],
                ),
              ),
      ),
    );
  }

  Widget _fixtureList(List<Fixture> list, Color color,
      {bool showCountdown = false, bool showScore = false}) {
    if (list.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: const [
          SizedBox(height: 100),
          Center(child: Text('Nothing here yet.')),
        ],
      );
    }
    return ListView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(12),
      itemCount: list.length,
      itemBuilder: (context, i) {
        final f = list[i];
        return Card(
          elevation: 1.5,
          margin: const EdgeInsets.only(bottom: 10),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          child: ListTile(
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            leading: CircleAvatar(
              backgroundColor: color.withOpacity(0.15),
              child: Icon(Icons.sports_soccer, color: color),
            ),
            title: Text('${f.homeTeam} vs ${f.awayTeam}',
                style: const TextStyle(fontWeight: FontWeight.w600)),
            subtitle: Text('${f.league}\n${formatDateTime(f.dateTimeUtc)}'),
            isThreeLine: true,
            trailing: showScore
                ? Text(
                    f.homeScore != null && f.awayScore != null
                        ? '${f.homeScore} - ${f.awayScore}'
                        : '-',
                    style: const TextStyle(fontWeight: FontWeight.bold))
                : Text(
                    countdownText(f.dateTimeUtc),
                    style: TextStyle(
                        color: color, fontWeight: FontWeight.w600),
                  ),
          ),
        );
      },
    );
  }

  Widget _standingsList(Color color) {
    if (standings.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: const [
          SizedBox(height: 100),
          Center(child: Text('Table not available for this competition.')),
        ],
      );
    }
    return SingleChildScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(12),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: ConstrainedBox(
          constraints:
              BoxConstraints(minWidth: MediaQuery.of(context).size.width - 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (standings.length <= 5)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Text(
                    'Showing top ${standings.length} — free API limit',
                    style: TextStyle(
                        color: Colors.grey.shade600,
                        fontSize: 12,
                        fontStyle: FontStyle.italic),
                  ),
                ),
              _standingsHeaderRow(),
              const Divider(height: 1),
              ...standings.map((row) {
                final isCurrent = row.teamName.toLowerCase() ==
                    widget.team.name.toLowerCase();
                return Container(
                  margin: const EdgeInsets.only(top: 6),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                  decoration: BoxDecoration(
                    color: isCurrent ? color.withOpacity(0.12) : null,
                    borderRadius: BorderRadius.circular(10),
                    border: isCurrent ? Border.all(color: color) : null,
                  ),
                  child: Row(
                    children: [
                      SizedBox(
                          width: 26,
                          child: Text(row.rank,
                              style:
                                  const TextStyle(fontWeight: FontWeight.bold))),
                      const SizedBox(width: 8),
                      row.badge.isNotEmpty
                          ? Image.network(row.badge,
                              width: 22,
                              height: 22,
                              errorBuilder: (_, __, ___) =>
                                  const Icon(Icons.sports_soccer, size: 18))
                          : const Icon(Icons.sports_soccer, size: 18),
                      const SizedBox(width: 10),
                      SizedBox(
                        width: 140,
                        child: Text(row.teamName,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontWeight: isCurrent
                                    ? FontWeight.bold
                                    : FontWeight.normal)),
                      ),
                      _statCell(row.played),
                      _statCell(row.win),
                      _statCell(row.draw),
                      _statCell(row.loss),
                      SizedBox(
                          width: 36,
                          child: Text(row.points,
                              textAlign: TextAlign.center,
                              style:
                                  const TextStyle(fontWeight: FontWeight.bold))),
                    ],
                  ),
                );
              }),
            ],
          ),
        ),
      ),
    );
  }

  Widget _statCell(String value) => SizedBox(
        width: 30,
        child: Text(value,
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey.shade600)),
      );

  Widget _standingsHeaderRow() {
    return Row(
      children: [
        const SizedBox(width: 26),
        const SizedBox(width: 30), // badge column
        const SizedBox(
          width: 140,
          child: Text('Team',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
        ),
        _headerCell('P'),
        _headerCell('W'),
        _headerCell('D'),
        _headerCell('L'),
        SizedBox(
          width: 36,
          child: Text('Pts',
              textAlign: TextAlign.center,
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
        ),
      ],
    );
  }

  Widget _headerCell(String label) => SizedBox(
        width: 30,
        child: Text(label,
            textAlign: TextAlign.center,
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
      );

  Widget _squadList(Color color) {
    if (squad.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: const [
          SizedBox(height: 100),
          Center(child: Text('Squad not available.')),
        ],
      );
    }
    return GridView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(12),
      itemCount: squad.length + (squad.length >= 10 ? 1 : 0),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        childAspectRatio: 0.78,
        crossAxisSpacing: 10,
        mainAxisSpacing: 10,
      ),
      itemBuilder: (context, i) {
        if (i >= squad.length) {
          return Center(
            child: Text(
              'Free API shows\nfirst 10 players',
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: Colors.grey.shade600,
                  fontSize: 12,
                  fontStyle: FontStyle.italic),
            ),
          );
        }
        final p = squad[i];
        return Card(
          elevation: 1.5,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              Expanded(
                child: Container(
                  width: double.infinity,
                  color: color.withOpacity(0.1),
                  child: p.photo.isNotEmpty
                      ? Image.network(p.photo,
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => Icon(Icons.person,
                              size: 40, color: color))
                      : Icon(Icons.person, size: 40, color: color),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: 8, vertical: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(p.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontWeight: FontWeight.w600, fontSize: 13)),
                    Text(p.position,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: Colors.grey.shade600, fontSize: 11)),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

// ---------- Search / add team ----------
class SearchTeamPage extends StatefulWidget {
  const SearchTeamPage({super.key});
  @override
  State<SearchTeamPage> createState() => _SearchTeamPageState();
}

class _SearchTeamPageState extends State<SearchTeamPage> {
  final controller = TextEditingController();
  List<Team> results = [];
  bool loading = false;

  Future<void> _search(String query) async {
    if (query.trim().isEmpty) return;
    setState(() => loading = true);
    try {
      final resp = await http.get(Uri.parse(
          'https://www.thesportsdb.com/api/v1/json/3/searchteams.php?t=${Uri.encodeComponent(query)}'));
      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body);
        final teams = data['teams'] as List<dynamic>?;
        setState(() {
          results = teams == null
              ? []
              : teams
                  .map((t) => Team(
                        id: t['idTeam'].toString(),
                        name: t['strTeam'] ?? '',
                        league: t['strLeague'] ?? '',
                        badge: pickBadge(t),
                        idLeague: t['idLeague']?.toString() ?? '',
                      ))
                  .toList();
        });
      }
    } catch (_) {
    } finally {
      setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
              hintText: 'Search for a team...', border: InputBorder.none),
          onSubmitted: _search,
        ),
        actions: [
          IconButton(
              icon: const Icon(Icons.search),
              onPressed: () => _search(controller.text))
        ],
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : ListView.builder(
              itemCount: results.length,
              itemBuilder: (context, i) {
                final t = results[i];
                final color = colorForTeam(t.name);
                return ListTile(
                  leading: CircleAvatar(
                    backgroundColor: color.withOpacity(0.15),
                    child: t.badge.isNotEmpty
                        ? ClipOval(
                            child: Image.network(t.badge,
                                width: 34,
                                height: 34,
                                errorBuilder: (_, __, ___) =>
                                    Icon(Icons.sports_soccer, color: color)))
                        : Icon(Icons.sports_soccer, color: color),
                  ),
                  title: Text(t.name),
                  subtitle: Text(t.league),
                  onTap: () => Navigator.pop(context, t),
                );
              },
            ),
    );
  }
}
