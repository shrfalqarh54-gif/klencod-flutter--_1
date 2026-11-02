import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

const String _tasksKey = 'injaz_tasks_v1';
const String _settingsKey = 'injaz_settings_v1';
const Color _purple = Color(0xFF6750A4);

enum TaskStatus { pending, done, notDone }

class PlannerTask {
  PlannerTask({
    required this.id,
    required this.dayKey,
    required this.text,
    required this.hour,
    required this.minute,
    required this.colorValue,
    this.status = TaskStatus.pending,
    this.repeatDaily = false,
  });

  final String id;
  final String dayKey;
  String text;
  int hour;
  int minute;
  int colorValue;
  TaskStatus status;
  bool repeatDaily;

  Map<String, dynamic> toJson() => {
        'id': id,
        'dayKey': dayKey,
        'text': text,
        'hour': hour,
        'minute': minute,
        'colorValue': colorValue,
        'status': status.name,
        'repeatDaily': repeatDaily,
      };

  factory PlannerTask.fromJson(Map<String, dynamic> json) {
    return PlannerTask(
      id: json['id'] as String,
      dayKey: json['dayKey'] as String,
      text: json['text'] as String? ?? '',
      hour: json['hour'] as int? ?? 9,
      minute: json['minute'] as int? ?? 0,
      colorValue: json['colorValue'] as int? ?? _purple.value,
      status: TaskStatus.values.firstWhere(
        (value) => value.name == json['status'],
        orElse: () => TaskStatus.pending,
      ),
      repeatDaily: json['repeatDaily'] as bool? ?? false,
    );
  }

  int get notificationId {
    var hash = 17;
    for (final unit in id.codeUnits) {
      hash = (hash * 31 + unit) & 0x7fffffff;
    }
    return 1000 + (hash % 800000000);
  }

  String get timeLabel =>
      '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';
}

class PlannerSettings {
  bool darkMode;
  bool english;
  bool notificationsEnabled;
  int reminderHour;
  int reminderMinute;

  PlannerSettings({
    this.darkMode = false,
    this.english = false,
    this.notificationsEnabled = true,
    this.reminderHour = 8,
    this.reminderMinute = 0,
  });

  Map<String, dynamic> toJson() => {
        'darkMode': darkMode,
        'english': english,
        'notificationsEnabled': notificationsEnabled,
        'reminderHour': reminderHour,
        'reminderMinute': reminderMinute,
      };

  factory PlannerSettings.fromJson(Map<String, dynamic> json) =>
      PlannerSettings(
        darkMode: json['darkMode'] as bool? ?? false,
        english: json['english'] as bool? ?? false,
        notificationsEnabled:
            json['notificationsEnabled'] as bool? ?? true,
        reminderHour: json['reminderHour'] as int? ?? 8,
        reminderMinute: json['reminderMinute'] as int? ?? 0,
      );
}

String dayKeyOf(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

DateTime dateFromKey(String key) {
  final parts = key.split('-').map(int.parse).toList();
  return DateTime(parts[0], parts[1], parts[2]);
}

String formatDate(DateTime date, bool english) {
  const arDays = ['الاثنين', 'الثلاثاء', 'الأربعاء', 'الخميس', 'الجمعة', 'السبت', 'الأحد'];
  const enDays = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
  const arMonths = ['يناير', 'فبراير', 'مارس', 'أبريل', 'مايو', 'يونيو', 'يوليو', 'أغسطس', 'سبتمبر', 'أكتوبر', 'نوفمبر', 'ديسمبر'];
  const enMonths = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];
  final day = english ? enDays[date.weekday - 1] : arDays[date.weekday - 1];
  final month = english ? enMonths[date.month - 1] : arMonths[date.month - 1];
  return english
      ? '$day, $month ${date.day}, ${date.year}'
      : '$day، ${date.day} $month ${date.year}';
}

class PlannerController extends ChangeNotifier {
  PlannerController._(this.prefs);

  final SharedPreferences prefs;
  final List<PlannerTask> tasks = [];
  PlannerSettings settings = PlannerSettings();

  static Future<PlannerController> create() async {
    final prefs = await SharedPreferences.getInstance();
    final controller = PlannerController._(prefs);
    await controller.load();
    await controller.prepareNewDay();
    return controller;
  }

  Future<void> load() async {
    tasks
      ..clear()
      ..addAll((prefs.getStringList(_tasksKey) ?? []).map((item) {
        return PlannerTask.fromJson(jsonDecode(item) as Map<String, dynamic>);
      }));
    final rawSettings = prefs.getString(_settingsKey);
    if (rawSettings != null) {
      settings = PlannerSettings.fromJson(
        jsonDecode(rawSettings) as Map<String, dynamic>,
      );
    }
  }

  Future<void> _save() async {
    await prefs.setStringList(
      _tasksKey,
      tasks.map((task) => jsonEncode(task.toJson())).toList(),
    );
    await prefs.setString(_settingsKey, jsonEncode(settings.toJson()));
  }

  Future<void> prepareNewDay() async {
    final today = dayKeyOf(DateTime.now());
    final lastDay = prefs.getString('injaz_last_open_day');
    if (lastDay != null && lastDay != today) {
      final previousRecurring = tasks
          .where((task) => task.dayKey == lastDay && task.repeatDaily)
          .toList();
      for (final old in previousRecurring) {
        tasks.add(PlannerTask(
          id: '${DateTime.now().microsecondsSinceEpoch}_${old.id}',
          dayKey: today,
          text: old.text,
          hour: old.hour,
          minute: old.minute,
          colorValue: old.colorValue,
          status: TaskStatus.pending,
          repeatDaily: true,
        ));
      }
    }
    await prefs.setString('injaz_last_open_day', today);
    await _save();
  }

  List<PlannerTask> get todayTasks {
    final key = dayKeyOf(DateTime.now());
    final result = tasks.where((task) => task.dayKey == key).toList();
    result.sort((a, b) {
      final first = a.hour * 60 + a.minute;
      final second = b.hour * 60 + b.minute;
      return first.compareTo(second);
    });
    return result;
  }

  List<String> get historyDays {
    final today = dayKeyOf(DateTime.now());
    return tasks
        .map((task) => task.dayKey)
        .where((key) => key != today)
        .toSet()
        .toList()
      ..sort((a, b) => b.compareTo(a));
  }

  Future<void> addTask({
    required String text,
    required TimeOfDay time,
    required int color,
    required bool repeatDaily,
  }) async {
    if (text.trim().isEmpty) return;
    tasks.add(PlannerTask(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      dayKey: dayKeyOf(DateTime.now()),
      text: text.trim(),
      hour: time.hour,
      minute: time.minute,
      colorValue: color,
      repeatDaily: repeatDaily,
    ));
    await _save();
    notifyListeners();
    await NotificationService.refresh(this);
  }

  Future<void> updateTask(
    PlannerTask task, {
    required String text,
    required TimeOfDay time,
    required int color,
    required bool repeatDaily,
  }) async {
    task
      ..text = text.trim()
      ..hour = time.hour
      ..minute = time.minute
      ..colorValue = color
      ..repeatDaily = repeatDaily;
    await _save();
    notifyListeners();
    await NotificationService.refresh(this);
  }

  Future<void> setStatus(PlannerTask task, TaskStatus status) async {
    task.status = status;
    await _save();
    notifyListeners();
    await NotificationService.refresh(this);
  }

  Future<void> deleteTask(PlannerTask task) async {
    tasks.removeWhere((item) => item.id == task.id);
    await _save();
    notifyListeners();
    await NotificationService.refresh(this);
  }

  Future<void> saveSettings() async {
    await _save();
    notifyListeners();
    await NotificationService.refresh(this);
  }

  Future<void> reloadFromBackground() async {
    await load();
    notifyListeners();
  }

  List<PlannerTask> tasksForDay(String key) =>
      tasks.where((task) => task.dayKey == key).toList()
        ..sort((a, b) => (a.hour * 60 + a.minute)
            .compareTo(b.hour * 60 + b.minute));
}

class NotificationService {
  static final FlutterLocalNotificationsPlugin plugin =
      FlutterLocalNotificationsPlugin();
  static const int summaryId = 900000;
  static const String groupKey = 'injaz_daily_tasks';

  static Future<void> initialize() async {
    tzdata.initializeTimeZones();
    try {
      final zone = await FlutterTimezone.getLocalTimezone();
      tz.setLocalLocation(tz.getLocation(zone.identifier));
    } catch (_) {
      tz.setLocalLocation(tz.getLocation('Asia/Aden'));
    }

    const android = AndroidInitializationSettings('ic_notification');
    const settings = InitializationSettings(android: android);
    await plugin.initialize(
      settings,
      onDidReceiveNotificationResponse: _handleForegroundResponse,
      onDidReceiveBackgroundNotificationResponse: notificationTapBackground,
    );

    final androidPlugin =
        plugin.resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
    await androidPlugin?.requestNotificationsPermission();
    await androidPlugin?.requestExactAlarmsPermission();
  }

  static Future<void> _handleForegroundResponse(
      NotificationResponse response) async {
    await notificationTapBackground(response);
  }

  static String _summaryBody(List<PlannerTask> pending, bool english) {
    final lines = pending.map((task) => '${task.timeLabel}  ${task.text}').join('\n');
    final text = lines.length > 3200 ? '${lines.substring(0, 3200)}…' : lines;
    return text.isEmpty
        ? (english ? 'No pending tasks.' : 'لا توجد مهام معلقة')
        : text;
  }

  static AndroidNotificationDetails _summaryDetails(bool english) =>
      AndroidNotificationDetails(
        'injaz_summary_channel',
        english ? 'Daily summary' : 'ملخص المهام اليومية',
        channelDescription:
            english ? 'Daily tasks summary' : 'ملخص مهام تطبيق إنجاز',
        importance: Importance.max,
        priority: Priority.max,
        playSound: true,
        ongoing: true,
        autoCancel: false,
        groupKey: groupKey,
        setAsGroupSummary: true,
      );

  static AndroidNotificationDetails _taskDetails(bool english) =>
      AndroidNotificationDetails(
        'injaz_task_channel',
        english ? 'Task reminders' : 'تذكيرات المهام',
        channelDescription:
            english ? 'One notification for each task' : 'إشعار مستقل لكل مهمة',
        importance: Importance.max,
        priority: Priority.max,
        playSound: true,
        ongoing: true,
        autoCancel: false,
        groupKey: groupKey,
        actions: <AndroidNotificationAction>[
          AndroidNotificationAction(
            'done',
            english ? 'Done' : 'تم',
            showsUserInterface: false,
            cancelNotification: true,
          ),
          AndroidNotificationAction(
            'not_done',
            english ? 'Not done' : 'لم يتم',
            showsUserInterface: false,
            cancelNotification: true,
          ),
        ],
      );

  static Future<void> refresh(PlannerController controller) async {
    await plugin.cancelAll();
    if (!controller.settings.notificationsEnabled) return;

    final today = dayKeyOf(DateTime.now());
    final pending =
        controller.tasksForDay(today).where((t) => t.status == TaskStatus.pending).toList();
    if (pending.isEmpty) return;

    final english = controller.settings.english;
    final now = tz.TZDateTime.now(tz.local);
    var reminder = tz.TZDateTime(
      tz.local,
      now.year,
      now.month,
      now.day,
      controller.settings.reminderHour,
      controller.settings.reminderMinute,
    );
    final shouldShowNow = !reminder.isAfter(now);
    if (!shouldShowNow) {
      for (final task in pending) {
        await _scheduleTask(task, english, reminder);
      }
      await _scheduleSummary(pending, english, reminder);
      return;
    }

    // If the app is opened after the chosen reminder time, show today's
    // reminder immediately and keep a daily alarm prepared for tomorrow.
    await _showSummary(pending, english);
    for (final task in pending) {
      await _showTask(task, english);
    }
    final tomorrow = reminder.add(const Duration(days: 1));
    for (final task in pending) {
      await _scheduleTask(task, english, tomorrow);
    }
    await _scheduleSummary(pending, english, tomorrow);
  }

  static Future<void> _scheduleTask(
      PlannerTask task, bool english, tz.TZDateTime when) async {
    final details = NotificationDetails(android: _taskDetails(english));
    try {
      await plugin.zonedSchedule(
        task.notificationId,
        task.text,
        '${english ? 'Start time' : 'وقت البداية'}: ${task.timeLabel}',
        when,
        details,
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
        matchDateTimeComponents: DateTimeComponents.time,
        payload: jsonEncode({'taskId': task.id, 'dayKey': task.dayKey}),
      );
    } catch (_) {
      await plugin.zonedSchedule(
        task.notificationId,
        task.text,
        '${english ? 'Start time' : 'وقت البداية'}: ${task.timeLabel}',
        when,
        details,
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        matchDateTimeComponents: DateTimeComponents.time,
        payload: jsonEncode({'taskId': task.id, 'dayKey': task.dayKey}),
      );
    }
  }

  static Future<void> _scheduleSummary(
      List<PlannerTask> pending, bool english, tz.TZDateTime when) async {
    final details = NotificationDetails(android: _summaryDetails(english));
    try {
      await plugin.zonedSchedule(
        summaryId,
        english ? 'Your daily tasks' : 'مهامك اليومية',
        _summaryBody(pending, english),
        when,
        details,
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
        matchDateTimeComponents: DateTimeComponents.time,
        payload: dayKeyOf(DateTime.now()),
      );
    } catch (_) {
      await plugin.zonedSchedule(
        summaryId,
        english ? 'Your daily tasks' : 'مهامك اليومية',
        _summaryBody(pending, english),
        when,
        details,
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        matchDateTimeComponents: DateTimeComponents.time,
        payload: dayKeyOf(DateTime.now()),
      );
    }
  }

  static Future<void> _showTask(PlannerTask task, bool english) async {
    await plugin.show(
      task.notificationId,
      task.text,
      '${english ? 'Start time' : 'وقت البداية'}: ${task.timeLabel}',
      NotificationDetails(android: _taskDetails(english)),
      payload: jsonEncode({'taskId': task.id, 'dayKey': task.dayKey}),
    );
  }

  static Future<void> _showSummary(
      List<PlannerTask> pending, bool english) async {
    await plugin.show(
      summaryId,
      english ? 'Your daily tasks' : 'مهامك اليومية',
      _summaryBody(pending, english),
      NotificationDetails(android: _summaryDetails(english)),
      payload: dayKeyOf(DateTime.now()),
    );
  }
}

@pragma('vm:entry-point')
Future<void> notificationTapBackground(NotificationResponse response) async {
  final action = response.actionId;
  if (action != 'done' && action != 'not_done') return;
  WidgetsFlutterBinding.ensureInitialized();

  Map<String, dynamic>? payload;
  try {
    payload = jsonDecode(response.payload ?? '') as Map<String, dynamic>;
  } catch (_) {
    return;
  }
  final taskId = payload['taskId'] as String?;
  final dayKey = payload['dayKey'] as String?;
  if (taskId == null || dayKey == null) return;

  final prefs = await SharedPreferences.getInstance();
  final raw = prefs.getStringList(_tasksKey) ?? [];
  final decoded = raw
      .map((item) => PlannerTask.fromJson(
          jsonDecode(item) as Map<String, dynamic>))
      .toList();

  PlannerTask? changed;
  for (final task in decoded) {
    if (task.id == taskId && task.dayKey == dayKey) {
      task.status =
          action == 'done' ? TaskStatus.done : TaskStatus.notDone;
      changed = task;
      break;
    }
  }
  if (changed == null) return;

  await prefs.setStringList(
      _tasksKey, decoded.map((task) => jsonEncode(task.toJson())).toList());

  final pending = decoded
      .where((task) => task.dayKey == dayKey && task.status == TaskStatus.pending)
      .toList();
  final notifications = FlutterLocalNotificationsPlugin();
  await notifications.initialize(
    const InitializationSettings(
      android: AndroidInitializationSettings('ic_notification'),
    ),
  );
  await notifications.cancel(changed.notificationId);

  if (pending.isEmpty) {
    await notifications.cancel(NotificationService.summaryId);
    for (final task in decoded.where((item) => item.dayKey == dayKey)) {
      await notifications.cancel(task.notificationId);
    }
  } else {
    final english = (jsonDecode(prefs.getString(_settingsKey) ?? '{}')
            as Map<String, dynamic>)['english'] as bool? ??
        false;
    final body = pending
        .map((task) => '${task.timeLabel}  ${task.text}')
        .join('\n');
    await notifications.show(
      NotificationService.summaryId,
      english ? 'Your daily tasks' : 'مهامك اليومية',
      body.length > 3200 ? '${body.substring(0, 3200)}…' : body,
      NotificationDetails(
        android: AndroidNotificationDetails(
          'injaz_summary_channel',
          english ? 'Daily summary' : 'ملخص المهام اليومية',
          channelDescription:
              english ? 'Daily tasks summary' : 'ملخص مهام تطبيق إنجاز',
          importance: Importance.max,
          priority: Priority.max,
          ongoing: true,
          autoCancel: false,
          groupKey: NotificationService.groupKey,
          setAsGroupSummary: true,
        ),
      ),
      payload: dayKey,
    );
  }
}

class InjazApp extends StatelessWidget {
  const InjazApp({super.key, required this.controller});
  final PlannerController controller;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final dark = controller.settings.darkMode;
        return MaterialApp(
          debugShowCheckedModeBanner: false,
          title: 'Injaz',
          themeMode: dark ? ThemeMode.dark : ThemeMode.light,
          theme: ThemeData(
            useMaterial3: true,
            colorScheme: ColorScheme.fromSeed(
              seedColor: _purple,
              brightness: Brightness.light,
            ),
            scaffoldBackgroundColor: const Color(0xFFF8F7FB),
            cardTheme: CardThemeData(
              elevation: 0,
              color: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
              ),
            ),
          ),
          darkTheme: ThemeData(
            useMaterial3: true,
            colorScheme: ColorScheme.fromSeed(
              seedColor: _purple,
              brightness: Brightness.dark,
            ),
            cardTheme: CardThemeData(
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
              ),
            ),
          ),
          home: PlannerHome(controller: controller),
        );
      },
    );
  }
}

class PlannerHome extends StatefulWidget {
  const PlannerHome({super.key, required this.controller});
  final PlannerController controller;

  @override
  State<PlannerHome> createState() => _PlannerHomeState();
}

class _PlannerHomeState extends State<PlannerHome> with WidgetsBindingObserver {
  int selectedTab = 0;
  PlannerController get c => widget.controller;
  bool get en => c.settings.english;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      c.reloadFromBackground().then((_) => NotificationService.refresh(c));
    }
  }

  String tr(String ar, String english) => en ? english : ar;

  @override
  Widget build(BuildContext context) {
    final pages = [
      _homePage(),
      _historyPage(),
      _statisticsPage(),
      _settingsPage(),
    ];
    return Directionality(
      textDirection: en ? TextDirection.ltr : TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: Text(tr('إنجاز', 'Injaz'),
              style: const TextStyle(fontWeight: FontWeight.w800)),
          centerTitle: false,
          actions: [
            Padding(
              padding: const EdgeInsetsDirectional.only(end: 16),
              child: Center(
                child: Text(
                  _shortDate(DateTime.now(), en),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ),
          ],
        ),
        body: IndexedStack(index: selectedTab, children: pages),
        floatingActionButton: selectedTab == 0
            ? FloatingActionButton.extended(
                onPressed: _openTaskEditor,
                backgroundColor: _purple,
                foregroundColor: Colors.white,
                icon: const Icon(Icons.add),
                label: Text(tr('إضافة مهمة', 'Add task')),
              )
            : null,
        bottomNavigationBar: NavigationBar(
          selectedIndex: selectedTab,
          onDestinationSelected: (value) =>
              setState(() => selectedTab = value),
          destinations: [
            NavigationDestination(
                icon: const Icon(Icons.checklist_rounded),
                label: tr('الرئيسية', 'Home')),
            NavigationDestination(
                icon: const Icon(Icons.history_rounded),
                label: tr('السجل', 'History')),
            NavigationDestination(
                icon: const Icon(Icons.bar_chart_rounded),
                label: tr('الإحصائيات', 'Stats')),
            NavigationDestination(
                icon: const Icon(Icons.settings_rounded),
                label: tr('الإعدادات', 'Settings')),
          ],
        ),
      ),
    );
  }

  String _shortDate(DateTime date, bool english) {
    final months = english
        ? ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec']
        : ['يناير', 'فبراير', 'مارس', 'أبريل', 'مايو', 'يونيو', 'يوليو', 'أغسطس', 'سبتمبر', 'أكتوبر', 'نوفمبر', 'ديسمبر'];
    return '${date.day} ${months[date.month - 1]}';
  }

  Widget _homePage() {
    final list = c.todayTasks;
    final completed = list.where((task) => task.status == TaskStatus.done).length;
    final pending = list.where((task) => task.status == TaskStatus.pending).length;
    final percent = list.isEmpty ? 0.0 : completed / list.length;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
      children: [
        Card(
          child: Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              gradient: LinearGradient(
                colors: Theme.of(context).brightness == Brightness.dark
                    ? [const Color(0xFF3B2E63), const Color(0xFF59458C)]
                    : [const Color(0xFF7259B5), const Color(0xFF9A83D3)],
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(tr('إنجاز اليوم', 'Today progress'),
                    style: const TextStyle(
                        color: Colors.white, fontWeight: FontWeight.w700)),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Text('${(percent * 100).round()}%',
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 34,
                            fontWeight: FontWeight.w800)),
                    const Spacer(),
                    Text('$completed ${tr('مكتملة', 'completed')}',
                        style: const TextStyle(color: Colors.white)),
                  ],
                ),
                const SizedBox(height: 12),
                ClipRRect(
                  borderRadius: BorderRadius.circular(20),
                  child: LinearProgressIndicator(
                    value: percent,
                    minHeight: 9,
                    backgroundColor: Colors.white.withValues(alpha: .25),
                    valueColor:
                        const AlwaysStoppedAnimation<Color>(Colors.white),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    _progressStat(tr('المهام', 'Tasks'), list.length),
                    const Spacer(),
                    _progressStat(tr('المتبقية', 'Remaining'), pending),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 18),
        Row(
          children: [
            Text(tr('مهام اليوم', 'Today tasks'),
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w800)),
            const Spacer(),
            Text('${list.length}',
                style: Theme.of(context).textTheme.labelLarge),
          ],
        ),
        const SizedBox(height: 10),
        if (list.isEmpty)
          _emptyState()
        else
          ...List.generate(list.length, (index) {
            final task = list[index];
            return _taskCard(task, index + 1);
          }),
        if (list.isNotEmpty && pending == 0)
          Card(
            color: Theme.of(context).colorScheme.primaryContainer,
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Row(
                children: [
                  const Icon(Icons.celebration_rounded, size: 30),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      tr('أحسنت! أكملت جميع مهام اليوم.', 'Great work! You completed all tasks today.'),
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _progressStat(String label, int value) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('$value', style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
          Text(label, style: const TextStyle(color: Colors.white70)),
        ],
      );

  Widget _emptyState() => Card(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 34, horizontal: 20),
          child: Column(
            children: [
              Icon(Icons.event_note_rounded,
                  size: 48, color: Theme.of(context).colorScheme.primary),
              const SizedBox(height: 12),
              Text(tr('لا توجد مهام اليوم', 'No tasks for today'),
                  style: const TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 6),
              Text(tr('أضف مهمتك الأولى من الزر بالأسفل.',
                  'Add your first task using the button below.')),
            ],
          ),
        ),
      );

  Widget _taskCard(PlannerTask task, int number) {
    final color = Color(task.colorValue);
    final isDone = task.status == TaskStatus.done;
    final isNotDone = task.status == TaskStatus.notDone;
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 5,
              height: 74,
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            const SizedBox(width: 12),
            Container(
              width: 30,
              height: 30,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: color.withValues(alpha: .12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text('$number',
                  style: TextStyle(
                      color: color, fontWeight: FontWeight.w800)),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    task.text,
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      decoration: isDone ? TextDecoration.lineThrough : null,
                      color: isDone
                          ? Theme.of(context).colorScheme.onSurfaceVariant
                          : null,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      const Icon(Icons.access_time_rounded, size: 15),
                      const SizedBox(width: 4),
                      Text(task.timeLabel,
                          style: Theme.of(context).textTheme.bodySmall),
                      if (task.repeatDaily) ...[
                        const SizedBox(width: 9),
                        const Icon(Icons.repeat_rounded, size: 14),
                      ],
                    ],
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: [
                      _statusChip(task, TaskStatus.done,
                          tr('تم', 'Done'), isDone),
                      _statusChip(task, TaskStatus.notDone,
                          tr('لم يتم', 'Not done'), isNotDone),
                      _statusChip(task, TaskStatus.pending,
                          tr('معلقة', 'Pending'),
                          task.status == TaskStatus.pending),
                    ],
                  ),
                ],
              ),
            ),
            PopupMenuButton<String>(
              onSelected: (value) {
                if (value == 'edit') _openTaskEditor(task: task);
                if (value == 'delete') _confirmDelete(task);
              },
              itemBuilder: (context) => [
                PopupMenuItem(
                    value: 'edit', child: Text(tr('تعديل', 'Edit'))),
                PopupMenuItem(
                    value: 'delete', child: Text(tr('حذف', 'Delete'))),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _statusChip(
      PlannerTask task, TaskStatus status, String label, bool selected) {
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      visualDensity: VisualDensity.compact,
      onSelected: (_) => c.setStatus(task, status),
    );
  }

  Future<void> _openTaskEditor({PlannerTask? task}) async {
    final textController = TextEditingController(text: task?.text ?? '');
    TimeOfDay time =
        task == null ? const TimeOfDay(hour: 9, minute: 0) : TimeOfDay(hour: task.hour, minute: task.minute);
    int color = task?.colorValue ?? _purple.value;
    bool repeat = task?.repeatDaily ?? false;
    final colors = <Color>[
      const Color(0xFF6750A4),
      const Color(0xFF287A72),
      const Color(0xFF3478C8),
      const Color(0xFFE18A32),
      const Color(0xFFD45C78),
      const Color(0xFF607D8B),
      const Color(0xFF7B8D35),
    ];

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            return Padding(
              padding: EdgeInsets.fromLTRB(
                  20, 8, 20, MediaQuery.of(context).viewInsets.bottom + 20),
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      task == null ? tr('مهمة جديدة', 'New task') : tr('تعديل المهمة', 'Edit task'),
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 14),
                    TextField(
                      controller: textController,
                      autofocus: true,
                      minLines: 2,
                      maxLines: 6,
                      keyboardType: TextInputType.multiline,
                      textInputAction: TextInputAction.newline,
                      decoration: InputDecoration(
                        hintText: tr('اكتب المهمة هنا...', 'Write your task here...'),
                        border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(16)),
                        alignLabelWithHint: true,
                      ),
                    ),
                    const SizedBox(height: 14),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.access_time_rounded),
                      title: Text(tr('وقت البداية', 'Start time')),
                      trailing: Text(time.format(context),
                          style: const TextStyle(fontWeight: FontWeight.w700)),
                      onTap: () async {
                        final picked = await showTimePicker(
                            context: context, initialTime: time);
                        if (picked != null) setSheetState(() => time = picked);
                      },
                    ),
                    const SizedBox(height: 6),
                    Text(tr('لون المهمة', 'Task color'),
                        style: const TextStyle(fontWeight: FontWeight.w700)),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 12,
                      children: colors.map((item) {
                        return InkWell(
                          onTap: () => setSheetState(() => color = item.value),
                          borderRadius: BorderRadius.circular(30),
                          child: Container(
                            width: 32,
                            height: 32,
                            decoration: BoxDecoration(
                              color: item,
                              shape: BoxShape.circle,
                              border: color == item.value
                                  ? Border.all(
                                      color: Theme.of(context).colorScheme.onSurface,
                                      width: 3)
                                  : null,
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                    const SizedBox(height: 10),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      value: repeat,
                      onChanged: (value) => setSheetState(() => repeat = value),
                      title: Text(tr('تكرار يومي', 'Repeat daily')),
                      subtitle: Text(tr('إنشاء نسخة جديدة غداً لهذه المهمة.',
                          'Create a fresh copy of this task tomorrow.')),
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: () async {
                          if (textController.text.trim().isEmpty) return;
                          if (task == null) {
                            await c.addTask(
                              text: textController.text,
                              time: time,
                              color: color,
                              repeatDaily: repeat,
                            );
                          } else {
                            await c.updateTask(
                              task,
                              text: textController.text,
                              time: time,
                              color: color,
                              repeatDaily: repeat,
                            );
                          }
                          if (sheetContext.mounted) Navigator.pop(sheetContext);
                        },
                        child: Text(tr('حفظ المهمة', 'Save task')),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
    textController.dispose();
  }

  Future<void> _confirmDelete(PlannerTask task) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr('حذف المهمة؟', 'Delete task?')),
        content: Text(tr('لن يمكن استعادة هذه المهمة بعد حذفها.',
            'This task cannot be restored after deletion.')),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(tr('إلغاء', 'Cancel'))),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(tr('حذف', 'Delete'))),
        ],
      ),
    );
    if (yes == true) await c.deleteTask(task);
  }

  Widget _historyPage() {
    final days = c.historyDays;
    if (days.isEmpty) {
      return Center(child: Text(tr('لا يوجد سجل سابق بعد.', 'No history yet.')));
    }
    return ListView(
      padding: const EdgeInsets.all(16),
      children: days.map((key) {
        final date = dateFromKey(key);
        final dayTasks = c.tasksForDay(key);
        final done = dayTasks.where((task) => task.status == TaskStatus.done).length;
        return Card(
          child: ExpansionTile(
            title: Text(formatDate(date, en),
                style: const TextStyle(fontWeight: FontWeight.w700)),
            subtitle: Text('$done / ${dayTasks.length} ${tr('مكتملة', 'completed')}'),
            children: dayTasks.isEmpty
                ? [ListTile(title: Text(tr('لا توجد مهام', 'No tasks')))]
                : dayTasks
                    .map((task) => ListTile(
                          leading: Icon(
                            task.status == TaskStatus.done
                                ? Icons.check_circle
                                : task.status == TaskStatus.notDone
                                    ? Icons.cancel_outlined
                                    : Icons.radio_button_unchecked,
                            color: Color(task.colorValue),
                          ),
                          title: Text(task.text),
                          subtitle: Text(task.timeLabel),
                          trailing: Text(_statusLabel(task.status)),
                        ))
                    .toList(),
          ),
        );
      }).toList(),
    );
  }

  String _statusLabel(TaskStatus status) {
    switch (status) {
      case TaskStatus.done:
        return tr('تم', 'Done');
      case TaskStatus.notDone:
        return tr('لم يتم', 'Not done');
      case TaskStatus.pending:
        return tr('معلقة', 'Pending');
    }
  }

  Widget _statisticsPage() {
    final now = DateTime.now();
    final start = DateTime(now.year, now.month, now.day)
        .subtract(Duration(days: now.weekday - 1));
    final days = List.generate(7, (i) => start.add(Duration(days: i)));
    var total = 0;
    var done = 0;
    final bars = <Widget>[];
    for (final day in days) {
      final items = c.tasksForDay(dayKeyOf(day));
      final completed = items.where((t) => t.status == TaskStatus.done).length;
      total += items.length;
      done += completed;
      final ratio = items.isEmpty ? 0.0 : completed / items.length;
      bars.add(Expanded(
        child: Column(
          children: [
            Expanded(
              child: Align(
                alignment: Alignment.bottomCenter,
                child: FractionallySizedBox(
                  heightFactor: ratio == 0 ? .025 : ratio,
                  child: Container(
                    width: 22,
                    decoration: BoxDecoration(
                      color: _purple,
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(en
                ? ['M', 'T', 'W', 'T', 'F', 'S', 'S'][day.weekday - 1]
                : ['ن', 'ث', 'ر', 'خ', 'ج', 'س', 'ح'][day.weekday - 1]),
          ],
        ),
      ));
    }
    final ratio = total == 0 ? 0.0 : done / total;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(tr('إحصائيات هذا الأسبوع', 'This week'),
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
                const SizedBox(height: 18),
                SizedBox(height: 150, child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: bars)),
                const SizedBox(height: 18),
                Text('${(ratio * 100).round()}% ${tr('نسبة الإنجاز', 'completion rate')}',
                    style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 18)),
                const SizedBox(height: 8),
                LinearProgressIndicator(value: ratio, minHeight: 8),
                const SizedBox(height: 12),
                Text('$done ${tr('مكتملة من أصل', 'completed out of')} $total ${tr('مهمة', 'tasks')}'),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _settingsPage() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: Column(
            children: [
              SwitchListTile(
                secondary: const Icon(Icons.dark_mode_outlined),
                title: Text(tr('الوضع الداكن', 'Dark mode')),
                value: c.settings.darkMode,
                onChanged: (value) {
                  c.settings.darkMode = value;
                  c.saveSettings();
                },
              ),
              const Divider(height: 1),
              SwitchListTile(
                secondary: const Icon(Icons.language_rounded),
                title: Text(tr('اللغة الإنجليزية', 'English language')),
                subtitle: Text(tr('إيقاف الخيار يعيد العربية.', 'Turn off to use Arabic.')),
                value: c.settings.english,
                onChanged: (value) {
                  c.settings.english = value;
                  c.saveSettings();
                },
              ),
              const Divider(height: 1),
              SwitchListTile(
                secondary: const Icon(Icons.notifications_active_outlined),
                title: Text(tr('التذكير اليومي', 'Daily reminder')),
                value: c.settings.notificationsEnabled,
                onChanged: (value) {
                  c.settings.notificationsEnabled = value;
                  c.saveSettings();
                },
              ),
              ListTile(
                leading: const Icon(Icons.schedule_rounded),
                title: Text(tr('وقت التذكير', 'Reminder time')),
                subtitle: Text(
                    '${c.settings.reminderHour.toString().padLeft(2, '0')}:${c.settings.reminderMinute.toString().padLeft(2, '0')}'),
                trailing: const Icon(Icons.chevron_right),
                onTap: _chooseReminderTime,
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Card(
          child: ListTile(
            leading: const Icon(Icons.copy_all_rounded),
            title: Text(tr('نسخ قائمة مهام اليوم', 'Copy today tasks')),
            subtitle: Text(tr('نسخ المهام وأوقاتها وحالاتها.', 'Copy tasks, times and statuses.')),
            onTap: _copyToday,
          ),
        ),
        const SizedBox(height: 12),
        Card(
          child: ListTile(
            leading: const Icon(Icons.info_outline_rounded),
            title: Text(tr('حول التطبيق', 'About')),
            subtitle: Text(tr('تطبيق لتنظيم المهام اليومية دون إنترنت.',
                'An offline daily task planner.')),
          ),
        ),
      ],
    );
  }

  Future<void> _chooseReminderTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(
        hour: c.settings.reminderHour,
        minute: c.settings.reminderMinute,
      ),
    );
    if (picked == null) return;
    c.settings
      ..reminderHour = picked.hour
      ..reminderMinute = picked.minute;
    await c.saveSettings();
  }

  Future<void> _copyToday() async {
    final items = c.todayTasks;
    final buffer = StringBuffer();
    for (var i = 0; i < items.length; i++) {
      final task = items[i];
      buffer.writeln('${i + 1}. ${task.text.replaceAll('\n', ' ')} — ${task.timeLabel} — ${_statusLabel(task.status)}');
    }
    await Clipboard.setData(ClipboardData(text: buffer.toString()));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(tr('تم نسخ قائمة اليوم.', 'Today list copied.'))),
    );
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final controller = await PlannerController.create();
  await NotificationService.initialize();
  await NotificationService.refresh(controller);
  runApp(InjazApp(controller: controller));
}