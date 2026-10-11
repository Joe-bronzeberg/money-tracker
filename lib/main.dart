import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

const _store = FlutterSecureStorage();
Database? _db;
Future<Database> get db async => _db ??= await openDatabase(
    p.join(await getDatabasesPath(), 'mt.db'),
    version: 1, onCreate: (d, v) async {
  await d.execute('CREATE TABLE wallets(id INTEGER PRIMARY KEY, name TEXT NOT NULL, currency TEXT NOT NULL, opening INTEGER NOT NULL)');
  await d.execute('CREATE TABLE tx(id INTEGER PRIMARY KEY, wallet INTEGER NOT NULL, income INTEGER NOT NULL, amount INTEGER NOT NULL, category TEXT NOT NULL, note TEXT, ts INTEGER NOT NULL)');
  await d.execute('CREATE TABLE budgets(id INTEGER PRIMARY KEY, category TEXT, wallet INTEGER, limit_amt INTEGER NOT NULL)');
});

int? minor(String s) {
  final m = RegExp(r'^(\d{1,9})(?:\.(\d{1,2}))?$').firstMatch(s.trim());
  if (m == null) return null;
  return int.parse(m[1]!) * 100 + int.parse((m[2] ?? '').padRight(2, '0'));
}

String money(Object? v, Object? cur) => '${((v as int) / 100).toStringAsFixed(2)} $cur';

List<int> _kdf(String pin, List<int> salt) {
  final h = Hmac(sha256, utf8.encode(pin));
  var k = h.convert(salt).bytes;
  for (var i = 0; i < 60000; i++) {
    k = h.convert(k + salt).bytes;
  }
  return k;
}

Future<bool> ask(BuildContext c, String q) async =>
    await showDialog<bool>(
        context: c,
        builder: (_) => AlertDialog(content: Text(q), actions: [
              TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
              TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Yes')),
            ])) ??
    false;

void main() => runApp(const App());

class App extends StatelessWidget {
  const App({super.key});
  @override
  Widget build(BuildContext c) => MaterialApp(
      title: 'Money Tracker',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
          useMaterial3: true,
          colorScheme: const ColorScheme.light(primary: Colors.black, onPrimary: Colors.white, surface: Colors.white)),
      home: const Gate());
}

class Gate extends StatefulWidget {
  const Gate({super.key});
  @override
  State<Gate> createState() => _GateState();
}

class _GateState extends State<Gate> {
  bool? hasPin;
  bool open = false;
  @override
  void initState() {
    super.initState();
    _store.read(key: 'pin').then((v) => setState(() => hasPin = v != null));
  }

  @override
  Widget build(BuildContext c) {
    if (hasPin == null) return const Scaffold();
    if (open) return Home(onLock: () => setState(() => open = false));
    return PinScreen(setup: !hasPin!, onDone: () => setState(() { hasPin = true; open = true; }));
  }
}

class PinScreen extends StatefulWidget {
  final bool setup;
  final VoidCallback onDone;
  const PinScreen({super.key, required this.setup, required this.onDone});
  @override
  State<PinScreen> createState() => _PinState();
}

class _PinState extends State<PinScreen> {
  final c = TextEditingController();
  String? first, msg;
  bool busy = false;

  Future<void> submit() async {
    final pin = c.text;
    if (busy) return;
    if (!RegExp(r'^\d{4,8}$').hasMatch(pin)) { setState(() => msg = 'Use 4 to 8 digits'); return; }
    if (widget.setup) {
      if (first == null) { first = pin; c.clear(); setState(() => msg = 'Repeat the PIN'); return; }
      if (first != pin) { first = null; c.clear(); setState(() => msg = 'PINs did not match'); return; }
      busy = true;
      final salt = List<int>.generate(16, (_) => Random.secure().nextInt(256));
      await _store.write(key: 'salt', value: base64Encode(salt));
      await _store.write(key: 'pin', value: base64Encode(_kdf(pin, salt)));
      busy = false;
      widget.onDone();
      return;
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final until = int.tryParse(await _store.read(key: 'until') ?? '') ?? 0;
    if (now < until) { setState(() => msg = 'Too many attempts. Wait ${((until - now) / 1000).ceil()}s'); return; }
    busy = true;
    final salt = base64Decode((await _store.read(key: 'salt'))!);
    final ok = base64Encode(_kdf(pin, salt)) == await _store.read(key: 'pin');
    busy = false;
    if (ok) { await _store.write(key: 'fails', value: '0'); widget.onDone(); return; }
    final f = (int.tryParse(await _store.read(key: 'fails') ?? '') ?? 0) + 1;
    await _store.write(key: 'fails', value: '$f');
    if (f >= 5) await _store.write(key: 'until', value: '${now + 30000 * (1 << min(f - 5, 6))}');
    c.clear();
    if (mounted) setState(() => msg = 'Wrong PIN');
  }

  @override
  Widget build(BuildContext x) => Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text(widget.setup ? 'Create a PIN' : 'Enter PIN', style: const TextStyle(fontSize: 22)),
              const SizedBox(height: 16),
              TextField(
                  controller: c,
                  obscureText: true,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  maxLength: 8,
                  textAlign: TextAlign.center,
                  onSubmitted: (_) => submit()),
              if (msg != null) Text(msg!),
              const SizedBox(height: 12),
              FilledButton(onPressed: submit, child: const Text('Continue')),
            ]),
          ),
        ),
      );
}

const yel = Color(0xFFFFE9A6), gold = Color(0xFFF9BB00), cream = Color(0xFFFFF8E1), bg = Color(0xFFFFFDF7), softGold = Color(0xFFFFC94D);
const expCats = {'Food & Drink': Icons.restaurant, 'Transport': Icons.directions_bus, 'Shopping': Icons.shopping_bag, 'Bills': Icons.receipt_long, 'Health': Icons.favorite, 'Entertainment': Icons.movie, 'Other': Icons.category};
const incCats = {'Salary': Icons.work, 'Bonus': Icons.emoji_events, 'Allowance': Icons.payments, 'Investments': Icons.trending_up, 'Other': Icons.account_balance_wallet};
const palette = [Color(0xFFF9BB00), Color(0xFFE8864B), Color(0xFF4CAF7D), Color(0xFF4A90E2), Color(0xFFE56B8A), Color(0xFF8E7CC3), Color(0xFF8A8A8A)];
const bold = TextStyle(fontWeight: FontWeight.bold);

Widget tile(IconData i, Color c) => Container(width: 44, height: 44, decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(12)), child: Icon(i, color: Colors.white));
IconData iconOf(String c, bool inc) => (inc ? incCats : expCats)[c] ?? Icons.category;
Color colorOf(String c) => palette[c.codeUnits.fold(0, (a, b) => a + b) % palette.length];
String mn(int v, Object? c) => '$c${(v / 100).toStringAsFixed(2)}';

Widget tabsBar(List<String> l, int sel, void Function(int) on) => Row(children: [
      for (var i = 0; i < l.length; i++)
        Expanded(
            child: InkWell(
                onTap: () => on(i),
                child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(border: Border(bottom: BorderSide(width: 3, color: sel == i ? Colors.black : Colors.transparent))),
                    child: Text(l[i], style: TextStyle(fontWeight: sel == i ? FontWeight.bold : FontWeight.normal)))))
    ]);

class Donut extends CustomPainter {
  final List<double> v;
  Donut(this.v);
  @override
  void paint(Canvas c, Size s) {
    final r = Rect.fromLTWH(14, 14, s.width - 28, s.height - 28);
    final p = Paint()..style = PaintingStyle.stroke..strokeWidth = 28..color = const Color(0xFFF1EFEA);
    c.drawArc(r, 0, 6.2832, false, p);
    final t = v.fold(0.0, (a, b) => a + b);
    if (t == 0) return;
    var a0 = -1.5708;
    for (var i = 0; i < v.length; i++) {
      final sw = v[i] / t * 6.2832;
      p.color = palette[i % palette.length];
      c.drawArc(r, a0, sw, false, p);
      a0 += sw;
    }
  }
  @override
  bool shouldRepaint(_) => true;
}

class Home extends StatefulWidget {
  final VoidCallback onLock;
  const Home({super.key, required this.onLock});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  int tab = 0, kind = 0;
  DateTime month = DateTime(DateTime.now().year, DateTime.now().month);
  List<Map<String, Object?>> wallets = [], txs = [], budgets = [];
  Map<int, int> spent = {};
  int get from => month.millisecondsSinceEpoch;
  int get to => DateTime(month.year, month.month + 1).millisecondsSinceEpoch;
  String get cur => wallets.isEmpty ? 'ZMW' : '${wallets.first['currency']}';
  int get total => wallets.where((w) => w['currency'] == cur).fold(0, (a, w) => a + (w['bal'] as int));
  int sum(bool inc) => txs.where((t) => t['currency'] == cur && (t['income'] == 1) == inc).fold(0, (a, t) => a + (t['amount'] as int));

  @override
  void initState() { super.initState(); load(); }

  Future<void> load() async {
    final d = await db;
    if ((await d.query('wallets', limit: 1)).isEmpty) await d.insert('wallets', {'name': 'Cash', 'currency': 'ZMW', 'opening': 0});
    wallets = await d.rawQuery('SELECT w.*, w.opening + COALESCE((SELECT SUM(CASE income WHEN 1 THEN amount ELSE -amount END) FROM tx WHERE wallet=w.id),0) AS bal FROM wallets w ORDER BY id');
    txs = await d.rawQuery('SELECT t.*, w.currency FROM tx t JOIN wallets w ON w.id=t.wallet WHERE ts>=? AND ts<? ORDER BY ts DESC', [from, to]);
    budgets = await d.query('budgets');
    spent = {};
    for (final b in budgets) {
      final r = await d.rawQuery('SELECT COALESCE(SUM(amount),0) s FROM tx WHERE income=0 AND ts>=? AND ts<? AND (? IS NULL OR category=?) AND (? IS NULL OR wallet=?)',
          [from, to, b['category'], b['category'], b['wallet'], b['wallet']]);
      spent[b['id'] as int] = r.first['s'] as int;
    }
    if (mounted) setState(() {});
  }

  void shift(int n) { month = DateTime(month.year, month.month + n); load(); }

  Future<void> addTx([Map<String, Object?>? pre]) async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => TxPage(wallets: wallets, pre: pre)));
    load();
  }

  Future<void> addWallet() async {
    final n = TextEditingController(), cur = TextEditingController(text: 'ZMW'), o = TextEditingController(text: '0');
    final ok = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(title: const Text('New wallet'), content: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(controller: n, maxLength: 30, decoration: const InputDecoration(labelText: 'Name')),
              TextField(controller: cur, maxLength: 3, textCapitalization: TextCapitalization.characters, decoration: const InputDecoration(labelText: 'Currency code')),
              TextField(controller: o, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Opening balance')),
            ]), actions: [
              TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
              TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Save')),
            ]));
    final ob = minor(o.text);
    if (ok != true || n.text.trim().isEmpty || !RegExp(r'^[A-Za-z]{3}$').hasMatch(cur.text) || ob == null) return;
    await (await db).insert('wallets', {'name': n.text.trim(), 'currency': cur.text.toUpperCase(), 'opening': ob});
    load();
  }

  Future<void> addBudget() async {
    final cat = TextEditingController(), lim = TextEditingController();
    int? w;
    final ok = await showDialog<bool>(
        context: context,
        builder: (_) => StatefulBuilder(builder: (ctx, set) => AlertDialog(title: const Text('New monthly budget'), content: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(controller: cat, maxLength: 30, decoration: const InputDecoration(labelText: 'Category (empty = all)')),
              DropdownButtonFormField<int?>(
                  value: w,
                  decoration: const InputDecoration(labelText: 'Wallet'),
                  items: [const DropdownMenuItem(value: null, child: Text('All wallets')), for (final x in wallets) DropdownMenuItem(value: x['id'] as int, child: Text('${x['name']}'))],
                  onChanged: (v) => set(() => w = v)),
              TextField(controller: lim, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Limit')),
            ]), actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
              TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save')),
            ])));
    final l = minor(lim.text);
    if (ok != true || l == null || l == 0) return;
    await (await db).insert('budgets', {'category': cat.text.trim().isEmpty ? null : cat.text.trim(), 'wallet': w, 'limit_amt': l});
    load();
  }


  Widget budgetList() => budgets.isEmpty
      ? const Center(child: Text('No budgets yet'))
      : ListView(children: [
          for (final b in budgets)
            Builder(builder: (_) {
              final s = spent[b['id']] ?? 0, l = b['limit_amt'] as int;
              final wn = wallets.where((w) => w['id'] == b['wallet']).map((w) => w['name']).join();
              return ListTile(
                title: Text('${b['category'] ?? 'All spending'} · ${wn.isEmpty ? 'all wallets' : wn}'),
                subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  LinearProgressIndicator(value: (s / l).clamp(0, 1).toDouble()),
                  Text('${(s / 100).toStringAsFixed(2)} of ${(l / 100).toStringAsFixed(2)}${s > l ? ' (over)' : ''}'),
                ]),
                trailing: IconButton(
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () async {
                      if (await ask(context, 'Delete this budget?')) {
                        await (await db).delete('budgets', where: 'id=?', whereArgs: [b['id']]);
                        load();
                      }
                    }),
              );
            })
        ]);

  Widget walletTab() => wallets.isEmpty
      ? const Center(child: Text('Add a wallet to begin'))
      : ListView(children: [
          for (final w in wallets)
            ListTile(
              title: Text('${w['name']}'),
              subtitle: const Text('Balance carries forward across months'),
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                Text(money(w['bal'], w['currency'])),
                IconButton(
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () async {
                      if (await ask(context, 'Delete this wallet and its transactions?')) {
                        final d = await db;
                        await d.delete('tx', where: 'wallet=?', whereArgs: [w['id']]);
                        await d.delete('budgets', where: 'wallet=?', whereArgs: [w['id']]);
                        await d.delete('wallets', where: 'id=?', whereArgs: [w['id']]);
                        load();
                      }
                    }),
              ]),
            )
        ]);



  Widget card(IconData i, Color c, String l, int v) => Expanded(
      child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16)),
          child: Row(children: [
            Container(padding: const EdgeInsets.all(10), decoration: BoxDecoration(color: c.withOpacity(.12), borderRadius: BorderRadius.circular(12)), child: Icon(i, color: c)),
            const SizedBox(width: 10),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(l, style: const TextStyle(color: Colors.black54)), Text(mn(v, cur), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600))])),
          ])));

  Widget empty(IconData i, String t) => Center(child: Column(mainAxisSize: MainAxisSize.min, children: [Icon(i, size: 96, color: softGold), const SizedBox(height: 12), Text(t, style: const TextStyle(color: Colors.black54))]));

  Widget txTab() {
    final rows = <Widget>[];
    String? day;
    for (final t in txs) {
      final ds = DateTime.fromMillisecondsSinceEpoch(t['ts'] as int).toString().substring(0, 10);
      if (ds != day) { day = ds; rows.add(Padding(padding: const EdgeInsets.fromLTRB(16, 14, 16, 2), child: Text(ds, style: const TextStyle(color: Colors.black54)))); }
      final inc = t['income'] == 1, c = '${t['category']}';
      rows.add(ListTile(
        leading: tile(iconOf(c, inc), colorOf(c)),
        title: Text(c),
        subtitle: (t['note'] ?? '') == '' ? null : Text('${t['note']}'),
        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
          Text('${inc ? '+' : '-'}${mn(t['amount'] as int, t['currency'])}', style: TextStyle(color: inc ? Colors.teal : Colors.black87, fontWeight: FontWeight.w600)),
          PopupMenuButton<String>(
              onSelected: (v) async {
                if (v == 'dup') addTx(t);
                if (v == 'del' && await ask(context, 'Delete this transaction?')) {
                  await (await db).delete('tx', where: 'id=?', whereArgs: [t['id']]);
                  load();
                }
              },
              itemBuilder: (_) => const [PopupMenuItem(value: 'dup', child: Text('Duplicate')), PopupMenuItem(value: 'del', child: Text('Delete'))]),
        ]),
      ));
    }
    return Column(children: [
      Container(width: double.infinity, color: yel, padding: const EdgeInsets.fromLTRB(16, 0, 16, 16), child: Column(children: [
        const Text('Total Balance', style: TextStyle(color: Colors.black54)),
        Text(mn(total, cur), style: const TextStyle(fontSize: 38, fontWeight: FontWeight.w600)),
        const SizedBox(height: 12),
        Row(children: [card(Icons.arrow_upward, Colors.deepOrange, 'Expense', sum(false)), const SizedBox(width: 12), card(Icons.arrow_downward, Colors.teal, 'Income', sum(true))]),
      ])),
      const Padding(padding: EdgeInsets.all(16), child: Align(alignment: Alignment.centerLeft, child: Text('Transactions', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)))),
      Expanded(child: txs.isEmpty ? empty(Icons.edit_calendar_outlined, 'No transactions yet. Tap + to add one.') : ListView(children: rows)),
    ]);
  }

  Widget reportTab() {
    final inc = kind == 1;
    final m = <String, int>{};
    for (final t in txs) {
      if (t['currency'] == cur && (t['income'] == 1) == inc) m['${t['category']}'] = (m['${t['category']}'] ?? 0) + (t['amount'] as int);
    }
    final e = m.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    final tot = e.fold(0, (a, x) => a + x.value);
    return ListView(padding: const EdgeInsets.all(16), children: [
      Text('${inc ? 'Income' : 'Expense'} by category', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
      SizedBox(height: 250, child: Stack(alignment: Alignment.center, children: [CustomPaint(size: const Size(240, 240), painter: Donut([for (final x in e) x.value.toDouble()])), Text(mn(tot, cur), style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold))])),
      const Text('Ranking', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
      if (e.isEmpty) const Padding(padding: EdgeInsets.all(24), child: Center(child: Text('Nothing recorded this month'))),
      for (var i = 0; i < e.length; i++)
        ListTile(
          leading: tile(iconOf(e[i].key, inc), palette[i % palette.length]),
          title: Text(e[i].key),
          subtitle: LinearProgressIndicator(value: e[i].value / tot, color: palette[i % palette.length], backgroundColor: cream),
          trailing: Text(mn(e[i].value, cur)),
        ),
    ]);
  }

  Widget budgetTab() => budgets.isEmpty
      ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.savings_outlined, size: 96, color: softGold),
          const SizedBox(height: 12),
          const Text('Set a monthly limit and stay on track', style: TextStyle(color: Colors.black54)),
          const SizedBox(height: 16),
          FilledButton(style: FilledButton.styleFrom(backgroundColor: gold, foregroundColor: Colors.black), onPressed: addBudget, child: const Text('CREATE NEW BUDGET')),
        ]))
      : budgetList();

  Widget mine(IconData i, String l, VoidCallback f) => InkWell(
      onTap: f,
      child: Container(
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16), boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 6)]),
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [Icon(i, size: 36, color: gold), const SizedBox(height: 8), Text(l)])));

  Widget mineTab() => GridView.count(crossAxisCount: 3, padding: const EdgeInsets.all(16), mainAxisSpacing: 12, crossAxisSpacing: 12, children: [
        mine(Icons.account_balance_wallet, 'Wallets', () => setState(() => tab = 4)),
        mine(Icons.lock_outline, 'Lock', widget.onLock),
        mine(Icons.delete_outline, 'Delete data', () async {
          if (await ask(context, 'Delete ALL data on this device?')) {
            final d = await db;
            for (final t in ['tx', 'budgets', 'wallets']) { await d.delete(t); }
            load();
          }
        }),
      ]);

  Widget nav(int i, IconData ic, String l) => InkWell(
      onTap: () => setState(() => tab = i),
      child: Padding(padding: const EdgeInsets.all(6), child: Column(mainAxisSize: MainAxisSize.min, children: [Icon(ic, color: tab == i ? gold : Colors.black45), Text(l, style: TextStyle(fontSize: 12, color: tab == i ? gold : Colors.black45))])));

  @override
  Widget build(BuildContext c) => Scaffold(
        backgroundColor: bg,
        appBar: AppBar(
          backgroundColor: yel, elevation: 0, scrolledUnderElevation: 0,
          leading: tab == 4 ? IconButton(icon: const Icon(Icons.arrow_back), onPressed: () => setState(() => tab = 3)) : null,
          title: Text(['My Wallet', 'My Wallet', 'Budget', 'Mine', 'Wallets'][tab], style: bold),
          actions: [
            if (tab < 2) ...[
              IconButton(icon: const Icon(Icons.chevron_left), onPressed: () => shift(-1)),
              Center(child: Text('${month.year} ${['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'][month.month - 1]}')),
              IconButton(icon: const Icon(Icons.chevron_right), onPressed: () => shift(1)),
            ],
            if (tab == 2) IconButton(icon: const Icon(Icons.add_box), onPressed: addBudget),
            if (tab == 4) IconButton(icon: const Icon(Icons.add_box), onPressed: addWallet),
          ],
          bottom: tab == 1 ? PreferredSize(preferredSize: const Size.fromHeight(48), child: tabsBar(['Expense', 'Income'], kind, (i) => setState(() => kind = i))) : null,
        ),
        body: [txTab(), reportTab(), budgetTab(), mineTab(), walletTab()][tab],
        floatingActionButton: FloatingActionButton(backgroundColor: gold, foregroundColor: Colors.black, shape: const CircleBorder(), onPressed: () => addTx(), child: const Icon(Icons.add, size: 32)),
        floatingActionButtonLocation: FloatingActionButtonLocation.centerDocked,
        bottomNavigationBar: BottomAppBar(
            shape: const CircularNotchedRectangle(), notchMargin: 8, color: Colors.white,
            child: Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [nav(0, Icons.list_alt, 'Transaction'), nav(1, Icons.bar_chart, 'Report'), const SizedBox(width: 56), nav(2, Icons.grid_view, 'Budget'), nav(3, Icons.person, 'Mine')])),
      );
}

class TxPage extends StatefulWidget {
  final List<Map<String, Object?>> wallets;
  final Map<String, Object?>? pre;
  const TxPage({super.key, required this.wallets, this.pre});
  @override
  State<TxPage> createState() => _TxPageState();
}

class _TxPageState extends State<TxPage> {
  late int wallet = (widget.pre?['wallet'] ?? widget.wallets.first['id']) as int;
  late bool income = widget.pre?['income'] == 1;
  late String cat = (widget.pre?['category'] ?? 'Food & Drink') as String;
  late final amt = TextEditingController(text: widget.pre == null ? '' : ((widget.pre!['amount'] as int) / 100).toStringAsFixed(2));
  final note = TextEditingController();
  DateTime date = DateTime.now();
  String? err;
  Map<String, Object?> get w => widget.wallets.firstWhere((x) => x['id'] == wallet);

  Future<bool> save() async {
    final a = minor(amt.text);
    if (a == null || a == 0) { setState(() => err = 'Enter a valid amount'); return false; }
    await (await db).insert('tx', {'wallet': wallet, 'income': income ? 1 : 0, 'amount': a, 'category': cat, 'note': note.text.trim(), 'ts': date.millisecondsSinceEpoch});
    return true;
  }

  Future<void> pickCat() async {
    final m = income ? incCats : expCats;
    final r = await showModalBottomSheet<String>(
        context: context,
        builder: (c) => GridView.count(crossAxisCount: 3, padding: const EdgeInsets.all(16), children: [
              for (final e in m.entries)
                InkWell(onTap: () => Navigator.pop(c, e.key), child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [tile(e.value, colorOf(e.key)), const SizedBox(height: 6), Text(e.key, textAlign: TextAlign.center)])),
              InkWell(onTap: () => Navigator.pop(c, '+'), child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [tile(Icons.add, Colors.black54), const SizedBox(height: 6), const Text('New')])),
            ]));
    if (r == '+') {
      final t = TextEditingController();
      final ok = await showDialog<bool>(context: context, builder: (c) => AlertDialog(title: const Text('New category'), content: TextField(controller: t, maxLength: 30, autofocus: true), actions: [TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Add'))]));
      if (ok == true && t.text.trim().isNotEmpty) setState(() => cat = t.text.trim());
    } else if (r != null) {
      setState(() => cat = r);
    }
  }

  Future<void> pickWallet() async {
    final r = await showModalBottomSheet<int>(
        context: context,
        builder: (c) => ListView(children: [for (final x in widget.wallets) ListTile(leading: tile(Icons.account_balance_wallet, const Color(0xFF6BD68B)), title: Text('${x['name']} (${x['currency']})'), onTap: () => Navigator.pop(c, x['id'] as int))]));
    if (r != null) setState(() => wallet = r);
  }

  Widget field(IconData i, String label, Widget lead, String text, VoidCallback onTap) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(padding: const EdgeInsets.fromLTRB(16, 18, 16, 8), child: Row(children: [Icon(i, size: 18), const SizedBox(width: 8), Text(label, style: const TextStyle(color: Colors.black54))])),
        InkWell(onTap: onTap, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6), child: Row(children: [lead, const SizedBox(width: 14), Expanded(child: Text(text, style: const TextStyle(fontSize: 18))), const Icon(Icons.chevron_right)]))),
        const Divider(indent: 16, endIndent: 16),
      ]);

  @override
  Widget build(BuildContext c) => Scaffold(
        backgroundColor: bg,
        appBar: AppBar(
          backgroundColor: yel, elevation: 0, scrolledUnderElevation: 0,
          title: const Text('New Transaction', style: bold),
          bottom: PreferredSize(preferredSize: const Size.fromHeight(48), child: tabsBar(['Expense', 'Income'], income ? 1 : 0, (i) => setState(() { income = i == 1; cat = (income ? incCats : expCats).keys.first; }))),
        ),
        body: ListView(children: [
          Padding(padding: const EdgeInsets.fromLTRB(16, 24, 16, 0), child: Row(children: [
            Text('${w['currency']}', style: const TextStyle(fontSize: 48, color: gold)),
            const SizedBox(width: 12),
            Expanded(child: TextField(controller: amt, autofocus: true, keyboardType: const TextInputType.numberWithOptions(decimal: true), style: const TextStyle(fontSize: 48), decoration: const InputDecoration(hintText: '0', border: InputBorder.none))),
          ])),
          const Divider(indent: 16, endIndent: 16, color: gold),
          field(Icons.category_outlined, 'Category', tile(iconOf(cat, income), colorOf(cat)), cat, pickCat),
          field(Icons.account_balance_wallet_outlined, 'Payment Method', tile(Icons.account_balance_wallet, const Color(0xFF6BD68B)), '${w['name']} (${w['currency']})', pickWallet),
          field(Icons.event, 'Date', tile(Icons.calendar_month, softGold), date.toString().substring(0, 10), () async {
            final d = await showDatePicker(context: c, initialDate: date, firstDate: DateTime(2000), lastDate: DateTime.now().add(const Duration(days: 1)));
            if (d != null) setState(() => date = d);
          }),
          Padding(padding: const EdgeInsets.fromLTRB(16, 18, 16, 0), child: Row(children: const [Icon(Icons.notes, size: 18), SizedBox(width: 8), Text('Note', style: TextStyle(color: Colors.black54))])),
          Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: TextField(controller: note, maxLength: 100, decoration: const InputDecoration(hintText: 'Add a note', border: InputBorder.none))),
          if (err != null) Padding(padding: const EdgeInsets.all(16), child: Text(err!, style: const TextStyle(color: Colors.red))),
        ]),
        bottomNavigationBar: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(children: [
            Expanded(child: OutlinedButton(style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(52), foregroundColor: Colors.black54), onPressed: () async { if (await save()) { amt.clear(); note.clear(); setState(() => err = null); } }, child: const Text('CONTINUE'))),
            const SizedBox(width: 12),
            Expanded(child: FilledButton(style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52), backgroundColor: gold, foregroundColor: Colors.black), onPressed: () async { if (await save() && mounted) Navigator.pop(context); }, child: const Text('SAVE'))),
          ]),
        ),
      );
}
