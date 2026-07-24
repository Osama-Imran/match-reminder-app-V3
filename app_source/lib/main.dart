import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/timezone.dart' as tz;
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:permission_handler/permission_handler.dart';
import 'package:workmanager/workmanager.dart';

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

@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    try {
      tzdata.initializeTimeZones();
      const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
      const initSettings = InitializationSettings(android: androidInit);
      await notificationsPlugin.initialize(initSettings);

      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getStringList(kSelectedTeamsKey) ?? [];
      final teams = raw.map((s) => Team.fromJson(jsonDecode(s))).toList();
      final offset = prefs.getInt(kReminderOffsetKey) ?? kDefaultOffsetMinutes;
      await scheduleAllReminders(teams, offset);
    } catch (_) {}
    return Future.value(true);
  });
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  Workmanager().initialize(callbackDispatcher);
  Workmanager().registerPeriodicTask(
    'daily-match-sync',
    'dailySyncTask',
    frequency: const Duration(hours: 24),
    constraints: Constraints(networkType: NetworkType.connected),
    existingWorkPolicy: ExistingWorkPolicy.replace,
  );
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
      ),
      home: const HomePage(),
    );
  }
}

// ---------- Models ----------
class Team {
  final String id;
  final String name;
  final String league;
  final String badge;
  Team(
      {required this.id,
      required this.name,
      required this.league,
      required this.badge});
  Map<String, dynamic> toJson() =>
      {'id': id, 'name': name, 'league': league, 'badge': badge};
  factory Team.fromJson(Map<String, dynamic> j) => Team(
      id: j['id'], name: j['name'], league: j['league'], badge: j['badge']);
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
                      return Card(
                        margin: const EdgeInsets.only(bottom: 10),
                        clipBehavior: Clip.antiAlias,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14)),
                        child: InkWell(
                          onTap: () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                  builder: (_) => TeamFixturesPage(team: t))),
                          child: Row(
                            children: [
                              Container(width: 6, height: 74, color: color),
                              const SizedBox(width: 12),
                              CircleAvatar(
                                radius: 22,
                                backgroundColor: color.withOpacity(0.15),
                                child: t.badge.isNotEmpty
                                    ? ClipOval(
                                        child: Image.network(t.badge,
                                            width: 34,
                                            height: 34,
                                            errorBuilder: (_, __, ___) =>
                                                Icon(Icons.sports_soccer,
                                                    color: color)))
                                    : Icon(Icons.sports_soccer, color: color),
                              ),
                              const SizedBox(width: 14),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(t.name,
                                        style: const TextStyle(
                                            fontWeight: FontWeight.w600,
                                            fontSize: 16)),
                                    Text(t.league,
                                        style: TextStyle(
                                            color: Colors.grey.shade600)),
                                  ],
                                ),
                              ),
                              const Icon(Icons.chevron_right),
                              IconButton(
                                  icon: const Icon(Icons.delete_outline,
                                      color: Colors.redAccent),
                                  onPressed: () => _removeTeam(t)),
                            ],
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

class _TeamFixturesPageState extends State<TeamFixturesPage>
    with SingleTickerProviderStateMixin {
  late TabController tabController;
  List<Fixture> upcoming = [];
  List<Fixture> results = [];
  bool loading = true;

  @override
  void initState() {
    super.initState();
    tabController = TabController(length: 2, vsync: this);
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
      setState(() {
        upcoming = up;
        results = res;
      });
    } catch (_) {} finally {
      setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final color = colorForTeam(widget.team.name);
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.team.name),
        bottom: TabBar(controller: tabController, tabs: const [
          Tab(text: 'Upcoming'),
          Tab(text: 'Results'),
        ]),
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: TabBarView(
                controller: tabController,
                children: [
                  _fixtureList(upcoming, color, showCountdown: true),
                  _fixtureList(results, color, showScore: true),
                ],
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
          margin: const EdgeInsets.only(bottom: 10),
          child: ListTile(
            leading: CircleAvatar(
              backgroundColor: color.withOpacity(0.15),
              child: Icon(Icons.sports_soccer, color: color),
            ),
            title: Text('${f.homeTeam} vs ${f.awayTeam}'),
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
                        badge: t['strTeamBadge'] ?? '',
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
