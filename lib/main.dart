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

class Home extends StatefulWidget {
  final VoidCallback onLock;
  const Home({super.key, required this.onLock});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  int tab = 0;
  DateTime month = DateTime(DateTime.now().year, DateTime.now().month);
  List<Map<String, Object?>> wallets = [], txs = [], budgets = [];
  Map<int, int> spent = {};
  int get from => month.millisecondsSinceEpoch;
  int get to => DateTime(month.year, month.month + 1).millisecondsSinceEpoch;

  @override
  void initState() { super.initState(); load(); }

  Future<void> load() async {
    final d = await db;
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
    if (wallets.isEmpty) { setState(() => tab = 2); return; }
    final ok = await showModalBottomSheet<bool>(
        context: context, isScrollControlled: true, builder: (_) => TxForm(wallets: wallets, pre: pre));
    if (ok == true) load();
  }

  Future<void> addWallet() async {
    final n = TextEditingController(), cur = TextEditingController(text: 'USD'), o = TextEditingController(text: '0');
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

  Widget txTab() => txs.isEmpty
      ? const Center(child: Text('No transactions this month'))
      : ListView(children: [
          for (final t in txs)
            ListTile(
              title: Text('${t['category']}'),
              subtitle: Text('${DateTime.fromMillisecondsSinceEpoch(t['ts'] as int).toString().substring(0, 10)}${(t['note'] ?? '') == '' ? '' : ' · ${t['note']}'}'),
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                Text('${t['income'] == 1 ? '+' : '-'}${money(t['amount'], t['currency'])}'),
                PopupMenuButton<String>(
                    onSelected: (v) async {
                      if (v == 'dup') { addTx(t); }
                      if (v == 'del' && await ask(context, 'Delete this transaction?')) {
                        await (await db).delete('tx', where: 'id=?', whereArgs: [t['id']]);
                        load();
                      }
                    },
                    itemBuilder: (_) => const [PopupMenuItem(value: 'dup', child: Text('Duplicate')), PopupMenuItem(value: 'del', child: Text('Delete'))]),
              ]),
            )
        ]);

  Widget budgetTab() => budgets.isEmpty
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

  @override
  Widget build(BuildContext c) => Scaffold(
        appBar: AppBar(
          title: Row(mainAxisSize: MainAxisSize.min, children: [
            IconButton(icon: const Icon(Icons.chevron_left), onPressed: () => shift(-1)),
            Text('${month.year}-${month.month.toString().padLeft(2, '0')}'),
            IconButton(icon: const Icon(Icons.chevron_right), onPressed: () => shift(1)),
          ]),
          actions: [
            IconButton(icon: const Icon(Icons.lock_outline), onPressed: widget.onLock),
            PopupMenuButton<String>(
                onSelected: (_) async {
                  if (await ask(context, 'Delete ALL data on this device?')) {
                    final d = await db;
                    for (final t in ['tx', 'budgets', 'wallets']) { await d.delete(t); }
                    load();
                  }
                },
                itemBuilder: (_) => const [PopupMenuItem(value: 'wipe', child: Text('Delete all data'))]),
          ],
        ),
        body: [txTab(), budgetTab(), walletTab()][tab],
        floatingActionButton: FloatingActionButton(
            onPressed: () => [addTx, addBudget, addWallet][tab](), child: const Icon(Icons.add)),
        bottomNavigationBar: NavigationBar(selectedIndex: tab, onDestinationSelected: (i) => setState(() => tab = i), destinations: const [
          NavigationDestination(icon: Icon(Icons.list), label: 'Transactions'),
          NavigationDestination(icon: Icon(Icons.pie_chart_outline), label: 'Budgets'),
          NavigationDestination(icon: Icon(Icons.account_balance_wallet_outlined), label: 'Wallets'),
        ]),
      );
}

class TxForm extends StatefulWidget {
  final List<Map<String, Object?>> wallets;
  final Map<String, Object?>? pre;
  const TxForm({super.key, required this.wallets, this.pre});
  @override
  State<TxForm> createState() => _TxFormState();
}

class _TxFormState extends State<TxForm> {
  late int wallet = (widget.pre?['wallet'] ?? widget.wallets.first['id']) as int;
  late bool income = widget.pre?['income'] == 1;
  late final amt = TextEditingController(text: widget.pre == null ? '' : ((widget.pre!['amount'] as int) / 100).toStringAsFixed(2));
  late final cat = TextEditingController(text: '${widget.pre?['category'] ?? ''}');
  late final note = TextEditingController(text: '${widget.pre?['note'] ?? ''}');
  DateTime date = DateTime.now();
  String? err;

  Future<void> save() async {
    final a = minor(amt.text);
    if (a == null || a == 0) { setState(() => err = 'Enter a valid amount'); return; }
    if (cat.text.trim().isEmpty) { setState(() => err = 'Enter a category'); return; }
    await (await db).insert('tx', {'wallet': wallet, 'income': income ? 1 : 0, 'amount': a, 'category': cat.text.trim(), 'note': note.text.trim(), 'ts': date.millisecondsSinceEpoch});
    if (mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext c) => Padding(
        padding: EdgeInsets.fromLTRB(16, 16, 16, MediaQuery.of(c).viewInsets.bottom + 16),
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            SegmentedButton<bool>(segments: const [ButtonSegment(value: false, label: Text('Expense')), ButtonSegment(value: true, label: Text('Income'))], selected: {income}, onSelectionChanged: (s) => setState(() => income = s.first)),
            DropdownButtonFormField<int>(value: wallet, items: [for (final w in widget.wallets) DropdownMenuItem(value: w['id'] as int, child: Text('${w['name']} (${w['currency']})'))], onChanged: (v) => setState(() => wallet = v!)),
            TextField(controller: amt, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Amount')),
            TextField(controller: cat, maxLength: 30, decoration: const InputDecoration(labelText: 'Category')),
            Wrap(spacing: 6, children: [for (final x in ['Food', 'Transport', 'Bills', 'Shopping', 'Health', 'Salary', 'Other']) ActionChip(label: Text(x), onPressed: () => setState(() => cat.text = x))]),
            TextField(controller: note, maxLength: 100, decoration: const InputDecoration(labelText: 'Note (optional)')),
            Row(children: [
              TextButton(onPressed: () async {
                final d = await showDatePicker(context: c, initialDate: date, firstDate: DateTime(2000), lastDate: DateTime.now().add(const Duration(days: 1)));
                if (d != null) setState(() => date = d);
              }, child: Text(date.toString().substring(0, 10))),
              const Spacer(),
              if (err != null) Text(err!),
              FilledButton(onPressed: save, child: const Text('Save')),
            ]),
          ]),
        ),
      );
}
