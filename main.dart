import 'dart:async';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

// ==========================================
// 1. DATA MODELS
// ==========================================

class Product {
  final int? id;
  final String name;
  final double costPrice;
  final double sellingPrice;
  final int quantity;

  Product({
    this.id,
    required this.name,
    required this.costPrice,
    required this.sellingPrice,
    required this.quantity,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'cost_price': costPrice,
      'selling_price': sellingPrice,
      'quantity': quantity,
    };
  }

  factory Product.fromMap(Map<String, dynamic> map) {
    return Product(
      id: map['id'] as int?,
      name: map['name'] as String,
      costPrice: (map['cost_price'] as num).toDouble(),
      sellingPrice: (map['selling_price'] as num).toDouble(),
      quantity: map['quantity'] as int,
    );
  }

  Product copyWith({
    int? id,
    String? name,
    double? costPrice,
    double? sellingPrice,
    int? quantity,
  }) {
    return Product(
      id: id ?? this.id,
      name: name ?? this.name,
      costPrice: costPrice ?? this.costPrice,
      sellingPrice: sellingPrice ?? this.sellingPrice,
      quantity: quantity ?? this.quantity,
    );
  }
}

class TransactionRecord {
  final int? id;
  final int productId;
  final String type; // 'BUY' or 'SELL'
  final int quantity;
  final double price;
  final String date;

  // Joined fields for display
  final String? productName;
  final double? productCostPrice;

  TransactionRecord({
    this.id,
    required this.productId,
    required this.type,
    required this.quantity,
    required this.price,
    required this.date,
    this.productName,
    this.productCostPrice,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'product_id': productId,
      'type': type,
      'quantity': quantity,
      'price': price,
      'date': date,
    };
  }

  factory TransactionRecord.fromMap(Map<String, dynamic> map) {
    return TransactionRecord(
      id: map['id'] as int?,
      productId: map['product_id'] as int,
      type: map['type'] as String,
      quantity: map['quantity'] as int,
      price: (map['price'] as num).toDouble(),
      date: map['date'] as String,
      productName: map['product_name'] as String?,
      productCostPrice: map['product_cost_price'] != null
          ? (map['product_cost_price'] as num).toDouble()
          : null,
    );
  }

  // Profit calculation per sale: (Selling Price - Cost Price) * Quantity
  double get profit {
    if (type != 'SELL') return 0.0;
    final cost = productCostPrice ?? 0.0;
    return (price - cost) * quantity;
  }
}

// ==========================================
// 2. DATABASE HELPER (SQLite / sqflite)
// ==========================================

class DatabaseHelper {
  static final DatabaseHelper instance = DatabaseHelper._internal();
  static Database? _database;

  DatabaseHelper._internal();

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDatabase();
    return _database!;
  }

  Future<Database> _initDatabase() async {
    final dbPath = await getDatabasesPath();
    final path = p.join(dbPath, 'personal_inventory.db');

    return await openDatabase(
      path,
      version: 1,
      onCreate: _onCreate,
    );
  }

  Future<void> _onCreate(Database db, int version) async {
    // 1. Products Table
    await db.execute('''
      CREATE TABLE products(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        cost_price REAL NOT NULL,
        selling_price REAL NOT NULL,
        quantity INTEGER NOT NULL
      )
    ''');

    // 2. Transactions Table
    await db.execute('''
      CREATE TABLE transactions(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        product_id INTEGER NOT NULL,
        type TEXT NOT NULL CHECK(type IN ('BUY', 'SELL')),
        quantity INTEGER NOT NULL,
        price REAL NOT NULL,
        date TEXT NOT NULL,
        FOREIGN KEY (product_id) REFERENCES products (id) ON DELETE CASCADE
      )
    ''');

    // Seed default starter data for demo
    await db.rawInsert('''
      INSERT INTO products (name, cost_price, selling_price, quantity)
      VALUES
        ('USB-C Fast Charger', 8.50, 19.99, 15),
        ('Wireless Mouse', 12.00, 24.50, 8),
        ('Bluetooth Earbuds', 22.00, 49.00, 5)
    ''');
  }

  // Product Operations
  Future<int> insertProduct(Product product) async {
    final db = await database;
    return await db.insert('products', product.toMap());
  }

  Future<int> updateProduct(Product product) async {
    final db = await database;
    return await db.update(
      'products',
      product.toMap(),
      where: 'id = ?',
      whereArgs: [product.id],
    );
  }

  Future<int> deleteProduct(int id) async {
    final db = await database;
    return await db.delete('products', where: 'id = ?', whereArgs: [id]);
  }

  Future<List<Product>> getAllProducts() async {
    final db = await database;
    final List<Map<String, dynamic>> maps =
        await db.query('products', orderBy: 'name ASC');
    return maps.map((m) => Product.fromMap(m)).toList();
  }

  Future<Product?> getProductById(int id) async {
    final db = await database;
    final maps =
        await db.query('products', where: 'id = ?', whereArgs: [id], limit: 1);
    if (maps.isNotEmpty) {
      return Product.fromMap(maps.first);
    }
    return null;
  }

  // Transaction Operations
  // Wrapped inside an atomic SQLite transaction
  Future<void> recordTransaction({
    required int productId,
    required String type,
    required int quantity,
    required double price,
  }) async {
    final db = await database;

    await db.transaction((txn) async {
      // 1. Fetch current product
      final productMaps = await txn.query(
        'products',
        where: 'id = ?',
        whereArgs: [productId],
        limit: 1,
      );

      if (productMaps.isEmpty) {
        throw Exception('Product not found in database.');
      }

      final product = Product.fromMap(productMaps.first);
      int newQuantity = product.quantity;

      // 2. Adjust stock according to transaction type
      if (type == 'BUY') {
        newQuantity += quantity;
      } else if (type == 'SELL') {
        if (product.quantity < quantity) {
          throw Exception(
            'Insufficient stock! Current stock: ${product.quantity}, requested: $quantity',
          );
        }
        newQuantity -= quantity;
      } else {
        throw Exception('Invalid transaction type. Must be BUY or SELL.');
      }

      // 3. Update product quantity
      await txn.update(
        'products',
        {'quantity': newQuantity},
        where: 'id = ?',
        whereArgs: [productId],
      );

      // 4. Record transaction log
      final dateIso = DateTime.now().toIso8601String();
      await txn.insert('transactions', {
        'product_id': productId,
        'type': type,
        'quantity': quantity,
        'price': price,
        'date': dateIso,
      });
    });
  }

  // Query transactions with product info joined
  Future<List<TransactionRecord>> getAllTransactions() async {
    final db = await database;
    final result = await db.rawQuery('''
      SELECT 
        t.id,
        t.product_id,
        t.type,
        t.quantity,
        t.price,
        t.date,
        p.name AS product_name,
        p.cost_price AS product_cost_price
      FROM transactions t
      LEFT JOIN products p ON t.product_id = p.id
      ORDER BY t.date DESC
    ''');

    return result.map((m) => TransactionRecord.fromMap(m)).toList();
  }

  // Dashboard Aggregates
  Future<Map<String, double>> getDashboardMetrics() async {
    final products = await getAllProducts();
    final transactions = await getAllTransactions();

    // Total Inventory Value: sum of (cost_price * quantity)
    double totalInventoryValue = 0.0;
    for (final p in products) {
      if (p.quantity > 0) {
        totalInventoryValue += (p.costPrice * p.quantity);
      }
    }

    // Overall Net Profit: sum of profit on all SELL transactions
    // Profit per sale: (Selling Price - Cost Price) * Quantity
    double totalNetProfit = 0.0;
    for (final t in transactions) {
      if (t.type == 'SELL') {
        totalNetProfit += t.profit;
      }
    }

    return {
      'totalInventoryValue': totalInventoryValue,
      'totalNetProfit': totalNetProfit,
    };
  }
}

// ==========================================
// 3. MAIN APP & NAVIGATION
// ==========================================

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const PersonalInventoryApp());
}

class PersonalInventoryApp extends StatelessWidget {
  const PersonalInventoryApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Personal Inventory',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF0F766E), // Emerald / Teal
          brightness: Brightness.light,
        ),
        appBarTheme: const AppBarTheme(
          centerTitle: true,
          elevation: 0,
        ),
      ),
      home: const MainNavigationScreen(),
    );
  }
}

class MainNavigationScreen extends StatefulWidget {
  const MainNavigationScreen({super.key});

  @override
  State<MainNavigationScreen> createState() => _MainNavigationScreenState();
}

class _MainNavigationScreenState extends State<MainNavigationScreen> {
  int _currentIndex = 0;

  // Refresh callback for child screens
  void _onTabChanged(int index) {
    setState(() {
      _currentIndex = index;
    });
  }

  @override
  Widget build(BuildContext context) {
    final screens = [
      DashboardScreen(
        onNavigateToNewTransaction: () => _onTabChanged(2),
        onNavigateToAddProduct: () => _navigateToAddProduct(context),
      ),
      const ProductsListScreen(),
      NewTransactionScreen(
        onTransactionCompleted: () => _onTabChanged(3), // Navigate to history
      ),
      const HistoryScreen(),
    ];

    return Scaffold(
      body: IndexedStack(
        index: _currentIndex,
        children: screens,
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentIndex,
        onDestinationSelected: _onTabChanged,
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.dashboard_outlined),
            selectedIcon: Icon(Icons.dashboard),
            label: 'Dashboard',
          ),
          NavigationDestination(
            icon: Icon(Icons.inventory_2_outlined),
            selectedIcon: Icon(Icons.inventory_2),
            label: 'Products',
          ),
          NavigationDestination(
            icon: Icon(Icons.swap_horiz_outlined),
            selectedIcon: Icon(Icons.swap_horiz),
            label: 'Transact',
          ),
          NavigationDestination(
            icon: Icon(Icons.history_outlined),
            selectedIcon: Icon(Icons.history),
            label: 'History',
          ),
        ],
      ),
    );
  }

  void _navigateToAddProduct(BuildContext context) async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const AddEditProductScreen()),
    );
    if (result == true) {
      setState(() {});
    }
  }
}

// ==========================================
// 4. SCREEN 1: DASHBOARD / SUMMARY
// ==========================================

class DashboardScreen extends StatefulWidget {
  final VoidCallback onNavigateToNewTransaction;
  final VoidCallback onNavigateToAddProduct;

  const DashboardScreen({
    super.key,
    required this.onNavigateToNewTransaction,
    required this.onNavigateToAddProduct,
  });

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  final _currencyFormat = NumberFormat.currency(symbol: '$', decimalDigits: 2);
  bool _isLoading = true;
  double _totalNetProfit = 0.0;
  double _totalInventoryValue = 0.0;
  List<Product> _products = [];

  @override
  void initState() {
    super.initState();
    _loadDashboardData();
  }

  Future<void> _loadDashboardData() async {
    setState(() => _isLoading = true);
    try {
      final metrics = await DatabaseHelper.instance.getDashboardMetrics();
      final products = await DatabaseHelper.instance.getAllProducts();

      setState(() {
        _totalNetProfit = metrics['totalNetProfit'] ?? 0.0;
        _totalInventoryValue = metrics['totalInventoryValue'] ?? 0.0;
        _products = products;
        _isLoading = false;
      });
    } catch (e) {
      setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isProfitPositive = _totalNetProfit >= 0;

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Personal Inventory',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: _loadDashboardData,
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _loadDashboardData,
              child: ListView(
                padding: const EdgeInsets.all(16.0),
                children: [
                  // Net Profit Card
                  Card(
                    elevation: 1,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                      side: BorderSide(
                        color: isProfitPositive
                            ? Colors.green.shade300
                            : Colors.red.shade300,
                        width: 1.5,
                      ),
                    ),
                    color: isProfitPositive
                        ? Colors.green.shade50
                        : Colors.red.shade50,
                    child: Padding(
                      padding: const EdgeInsets.all(20.0),
                      children: [
                        Row(
                          children: [
                            CircleAvatar(
                              backgroundColor: isProfitPositive
                                  ? Colors.green.shade100
                                  : Colors.red.shade100,
                              child: Icon(
                                isProfitPositive
                                    ? Icons.trending_up
                                    : Icons.trending_down,
                                color: isProfitPositive
                                    ? Colors.green.shade800
                                    : Colors.red.shade800,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Total Net Profit',
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                    color: Colors.grey.shade700,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  _currencyFormat.format(_totalNetProfit),
                                  style: TextStyle(
                                    fontSize: 26,
                                    fontWeight: FontWeight.bold,
                                    color: isProfitPositive
                                        ? Colors.green.shade900
                                        : Colors.red.shade900,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        Text(
                          'Calculated from sales: (Selling Price - Cost Price) * Quantity',
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.grey.shade600,
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 12),

                  // Inventory Value Card
                  Card(
                    elevation: 1,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                      side: BorderSide(color: Colors.grey.shade200),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(20.0),
                      children: [
                        Row(
                          children: [
                            CircleAvatar(
                              backgroundColor: Colors.teal.shade50,
                              child: Icon(
                                Icons.warehouse_rounded,
                                color: Colors.teal.shade800,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Total Inventory Value',
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                    color: Colors.grey.shade700,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  _currencyFormat.format(_totalInventoryValue),
                                  style: const TextStyle(
                                    fontSize: 24,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        Text(
                          'Current stock evaluated at Cost Price: ${_products.length} products total',
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.grey.shade600,
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 20),

                  // Action Buttons Row
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: widget.onNavigateToNewTransaction,
                          icon: const Icon(Icons.add_shopping_cart),
                          label: const Text('Log Transaction'),
                          style: FilledButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: widget.onNavigateToAddProduct,
                          icon: const Icon(Icons.add_box),
                          label: const Text('Add Product'),
                          style: OutlinedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 24),

                  // Stock Overview Section Header
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'Stock Overview',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        '${_products.length} Items',
                        style: TextStyle(
                          fontSize: 14,
                          color: Colors.grey.shade600,
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 12),

                  // Product List with current stock
                  if (_products.isEmpty)
                    Container(
                      padding: const EdgeInsets.all(32),
                      alignment: Alignment.center,
                      child: Column(
                        children: [
                          Icon(Icons.inventory_2_outlined,
                              size: 48, color: Colors.grey.shade400),
                          const SizedBox(height: 12),
                          const Text(
                            'No products in inventory yet.',
                            style: TextStyle(fontSize: 16),
                          ),
                          const SizedBox(height: 8),
                          TextButton(
                            onPressed: widget.onNavigateToAddProduct,
                            child: const Text('Add Your First Product'),
                          ),
                        ],
                      ),
                    )
                  else
                    ..._products.map((p) {
                      final isLowStock = p.quantity <= 3;
                      final isOutOfStock = p.quantity == 0;

                      return Card(
                        margin: const EdgeInsets.only(bottom: 8),
                        elevation: 0.5,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                          side: BorderSide(
                            color: isOutOfStock
                                ? Colors.red.shade200
                                : Colors.grey.shade200,
                          ),
                        ),
                        child: ListTile(
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 8,
                          ),
                          leading: CircleAvatar(
                            backgroundColor: isOutOfStock
                                ? Colors.red.shade100
                                : (isLowStock
                                    ? Colors.amber.shade100
                                    : Colors.teal.shade50),
                            child: Text(
                              '${p.quantity}',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                color: isOutOfStock
                                    ? Colors.red.shade900
                                    : (isLowStock
                                        ? Colors.amber.shade900
                                        : Colors.teal.shade900),
                              ),
                            ),
                          ),
                          title: Text(
                            p.name,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          subtitle: Text(
                            'Cost: ${_currencyFormat.format(p.costPrice)}  |  Sell: ${_currencyFormat.format(p.sellingPrice)}',
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.grey.shade700,
                            ),
                          ),
                          trailing: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: isOutOfStock
                                  ? Colors.red.shade50
                                  : (isLowStock
                                      ? Colors.amber.shade50
                                      : Colors.green.shade50),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              isOutOfStock
                                  ? 'Out of Stock'
                                  : (isLowStock ? 'Low Stock' : 'In Stock'),
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                                color: isOutOfStock
                                    ? Colors.red.shade700
                                    : (isLowStock
                                        ? Colors.amber.shade800
                                        : Colors.green.shade700),
                              ),
                            ),
                          ),
                        ),
                      );
                    }),
                ],
              ),
            ),
    );
  }
}

// ==========================================
// 5. SCREEN 2: PRODUCTS LIST / MANAGEMENT
// ==========================================

class ProductsListScreen extends StatefulWidget {
  const ProductsListScreen({super.key});

  @override
  State<ProductsListScreen> createState() => _ProductsListScreenState();
}

class _ProductsListScreenState extends State<ProductsListScreen> {
  final _currencyFormat = NumberFormat.currency(symbol: '$', decimalDigits: 2);
  List<Product> _products = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadProducts();
  }

  Future<void> _loadProducts() async {
    setState(() => _isLoading = true);
    final products = await DatabaseHelper.instance.getAllProducts();
    setState(() {
      _products = products;
      _isLoading = false;
    });
  }

  Future<void> _deleteProduct(Product product) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Product'),
        content: Text(
          'Are you sure you want to delete "${product.name}"? All associated transactions will also be deleted.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirm == true && product.id != null) {
      await DatabaseHelper.instance.deleteProduct(product.id!);
      _loadProducts();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Deleted "${product.name}"')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Inventory Products',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _products.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.inventory_2_outlined,
                          size: 64, color: Colors.grey.shade400),
                      const SizedBox(height: 16),
                      const Text(
                        'No products found',
                        style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 8),
                      const Text('Tap "+" below to add a new inventory item.'),
                    ],
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.all(16),
                  itemCount: _products.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemBuilder: (context, index) {
                    final product = _products[index];
                    final margin = (product.sellingPrice - product.costPrice);

                    return Card(
                      elevation: 0.5,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                        side: BorderSide(color: Colors.grey.shade200),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(14.0),
                        child: Row(
                          children: [
                            Container(
                              width: 48,
                              height: 48,
                              decoration: BoxDecoration(
                                color: Colors.teal.shade50,
                                borderRadius: BorderRadius.circular(10),
                              ),
                              alignment: Alignment.center,
                              child: Text(
                                '${product.quantity}',
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 18,
                                  color: Colors.teal.shade900,
                                ),
                              ),
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    product.name,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 16,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    'Cost: ${_currencyFormat.format(product.costPrice)}  •  Sell: ${_currencyFormat.format(product.sellingPrice)}',
                                    style: TextStyle(
                                      fontSize: 13,
                                      color: Colors.grey.shade700,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    'Unit Margin: ${_currencyFormat.format(margin)}',
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w500,
                                      color: margin >= 0
                                          ? Colors.green.shade700
                                          : Colors.red.shade700,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            IconButton(
                              icon: const Icon(Icons.edit_outlined),
                              onPressed: () async {
                                final updated = await Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (context) =>
                                        AddEditProductScreen(product: product),
                                  ),
                                );
                                if (updated == true) _loadProducts();
                              },
                            ),
                            IconButton(
                              icon: const Icon(Icons.delete_outline,
                                  color: Colors.red),
                              onPressed: () => _deleteProduct(product),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
      floatingActionButton: FloatingActionButton(
        onPressed: () async {
          final added = await Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => const AddEditProductScreen(),
            ),
          );
          if (added == true) _loadProducts();
        },
        child: const Icon(Icons.add),
      ),
    );
  }
}

// ==========================================
// 6. SCREEN 2B: ADD / EDIT PRODUCT
// ==========================================

class AddEditProductScreen extends StatefulWidget {
  final Product? product;

  const AddEditProductScreen({super.key, this.product});

  @override
  State<AddEditProductScreen> createState() => _AddEditProductScreenState();
}

class _AddEditProductScreenState extends State<AddEditProductScreen> {
  final _formKey = GlobalKey<FormState>();
  late TextEditingController _nameController;
  late TextEditingController _costPriceController;
  late TextEditingController _sellingPriceController;
  late TextEditingController _quantityController;
  bool _isSaving = false;

  bool get isEditing => widget.product != null;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.product?.name ?? '');
    _costPriceController = TextEditingController(
      text: widget.product != null ? widget.product!.costPrice.toStringAsFixed(2) : '',
    );
    _sellingPriceController = TextEditingController(
      text: widget.product != null
          ? widget.product!.sellingPrice.toStringAsFixed(2)
          : '',
    );
    _quantityController = TextEditingController(
      text: widget.product != null ? widget.product!.quantity.toString() : '0',
    );
  }

  @override
  void dispose() {
    _nameController.dispose();
    _costPriceController.dispose();
    _sellingPriceController.dispose();
    _quantityController.dispose();
    super.dispose();
  }

  Future<void> _saveProduct() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _isSaving = true);

    final name = _nameController.text.trim();
    final costPrice = double.tryParse(_costPriceController.text.trim()) ?? 0.0;
    final sellingPrice =
        double.tryParse(_sellingPriceController.text.trim()) ?? 0.0;
    final quantity = int.tryParse(_quantityController.text.trim()) ?? 0;

    final newProduct = Product(
      id: widget.product?.id,
      name: name,
      costPrice: costPrice,
      sellingPrice: sellingPrice,
      quantity: quantity,
    );

    try {
      if (isEditing) {
        await DatabaseHelper.instance.updateProduct(newProduct);
      } else {
        await DatabaseHelper.instance.insertProduct(newProduct);
      }
      if (mounted) {
        Navigator.pop(context, true);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error saving product: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(isEditing ? 'Edit Product' : 'Add New Product'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20.0),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextFormField(
                controller: _nameController,
                decoration: const InputDecoration(
                  labelText: 'Product Name',
                  hintText: 'e.g. Wireless Mouse',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.label_outline),
                ),
                validator: (val) {
                  if (val == null || val.trim().isEmpty) {
                    return 'Please enter product name';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: _costPriceController,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: const InputDecoration(
                        labelText: 'Cost Price ($)',
                        hintText: '0.00',
                        border: OutlineInputBorder(),
                        prefixIcon: Icon(Icons.attach_money),
                      ),
                      validator: (val) {
                        if (val == null || val.trim().isEmpty) {
                          return 'Required';
                        }
                        final num = double.tryParse(val.trim());
                        if (num == null || num < 0) {
                          return 'Enter valid price';
                        }
                        return null;
                      },
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextFormField(
                      controller: _sellingPriceController,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: const InputDecoration(
                        labelText: 'Selling Price ($)',
                        hintText: '0.00',
                        border: OutlineInputBorder(),
                        prefixIcon: Icon(Icons.point_of_sale),
                      ),
                      validator: (val) {
                        if (val == null || val.trim().isEmpty) {
                          return 'Required';
                        }
                        final num = double.tryParse(val.trim());
                        if (num == null || num < 0) {
                          return 'Enter valid price';
                        }
                        return null;
                      },
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _quantityController,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: isEditing ? 'Current Quantity' : 'Initial Quantity',
                  hintText: '0',
                  border: const OutlineInputBorder(),
                  prefixIcon: const Icon(Icons.numbers),
                ),
                validator: (val) {
                  if (val == null || val.trim().isEmpty) {
                    return 'Please enter quantity';
                  }
                  final num = int.tryParse(val.trim());
                  if (num == null || num < 0) {
                    return 'Enter valid whole quantity >= 0';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 28),
              FilledButton(
                onPressed: _isSaving ? null : _saveProduct,
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: _isSaving
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : Text(
                        isEditing ? 'Update Product' : 'Save Product',
                        style: const TextStyle(fontSize: 16),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ==========================================
// 7. SCREEN 3: NEW TRANSACTION (BUY / SELL)
// ==========================================

class NewTransactionScreen extends StatefulWidget {
  final VoidCallback onTransactionCompleted;

  const NewTransactionScreen({
    super.key,
    required this.onTransactionCompleted,
  });

  @override
  State<NewTransactionScreen> createState() => _NewTransactionScreenState();
}

class _NewTransactionScreenState extends State<NewTransactionScreen> {
  final _formKey = GlobalKey<FormState>();
  String _transactionType = 'SELL'; // Default: SELL
  List<Product> _products = [];
  Product? _selectedProduct;
  final TextEditingController _quantityController = TextEditingController(text: '1');
  final TextEditingController _priceController = TextEditingController();
  bool _isLoading = true;
  bool _isSubmitting = false;

  @override
  void initState() {
    super.initState();
    _loadProducts();
  }

  @override
  void dispose() {
    _quantityController.dispose();
    _priceController.dispose();
    super.dispose();
  }

  Future<void> _loadProducts() async {
    setState(() => _isLoading = true);
    final products = await DatabaseHelper.instance.getAllProducts();
    setState(() {
      _products = products;
      if (products.isNotEmpty) {
        _selectedProduct = products.first;
        _updatePriceFromSelectedProduct();
      }
      _isLoading = false;
    });
  }

  void _updatePriceFromSelectedProduct() {
    if (_selectedProduct == null) return;
    if (_transactionType == 'SELL') {
      _priceController.text = _selectedProduct!.sellingPrice.toStringAsFixed(2);
    } else {
      _priceController.text = _selectedProduct!.costPrice.toStringAsFixed(2);
    }
  }

  void _onTypeChanged(String newType) {
    setState(() {
      _transactionType = newType;
      _updatePriceFromSelectedProduct();
    });
  }

  // Real-time calculation helpers
  double get _currentEnteredPrice =>
      double.tryParse(_priceController.text.trim()) ?? 0.0;
  int get _currentEnteredQuantity =>
      int.tryParse(_quantityController.text.trim()) ?? 0;

  double get _projectedSaleProfit {
    if (_transactionType != 'SELL' || _selectedProduct == null) return 0.0;
    // (Selling Price - Cost Price) * Quantity
    return (_currentEnteredPrice - _selectedProduct!.costPrice) *
        _currentEnteredQuantity;
  }

  double get _totalTransactionAmount {
    return _currentEnteredPrice * _currentEnteredQuantity;
  }

  Future<void> _submitTransaction() async {
    if (!_formKey.currentState!.validate()) return;
    if (_selectedProduct == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select a product')),
      );
      return;
    }

    final quantity = _currentEnteredQuantity;
    final price = _currentEnteredPrice;

    // Safety check for SELL stock
    if (_transactionType == 'SELL' && _selectedProduct!.quantity < quantity) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: Colors.red.shade700,
          content: Text(
            'Cannot sell $quantity items! Available stock is only ${_selectedProduct!.quantity}.',
          ),
        ),
      );
      return;
    }

    setState(() => _isSubmitting = true);

    try {
      await DatabaseHelper.instance.recordTransaction(
        productId: _selectedProduct!.id!,
        type: _transactionType,
        quantity: quantity,
        price: price,
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: Colors.green.shade800,
            content: Text(
              _transactionType == 'SELL'
                  ? 'Sale logged! Profit: $${_projectedSaleProfit.toStringAsFixed(2)}'
                  : 'Purchase logged! Added $quantity units to stock.',
            ),
          ),
        );
        // Reset form
        _quantityController.text = '1';
        await _loadProducts();
        widget.onTransactionCompleted();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: Colors.red.shade700,
            content: Text('Error: $e'),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isSubmitting = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Log Transaction',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _products.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24.0),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.info_outline, size: 48, color: Colors.grey),
                        const SizedBox(height: 12),
                        const Text(
                          'No products available to transact.',
                          style: TextStyle(fontSize: 16),
                        ),
                        const SizedBox(height: 8),
                        const Text('Please add products first before logging sales or purchases.'),
                      ],
                    ),
                  ),
                )
              : SingleChildScrollView(
                  padding: const EdgeInsets.all(20.0),
                  child: Form(
                    key: _formKey,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // Segmented Action Selector: BUY vs SELL
                        SegmentedButton<String>(
                          segments: const [
                            ButtonSegment<String>(
                              value: 'SELL',
                              label: Text('SELL (Sale)'),
                              icon: Icon(Icons.point_of_sale),
                            ),
                            ButtonSegment<String>(
                              value: 'BUY',
                              label: Text('BUY (Purchase)'),
                              icon: Icon(Icons.add_shopping_cart),
                            ),
                          ],
                          selected: {_transactionType},
                          onSelectionChanged: (Set<String> newSelection) {
                            _onTypeChanged(newSelection.first);
                          },
                          style: ButtonStyle(
                            backgroundColor: WidgetStateProperty.resolveWith<Color?>(
                              (states) {
                                if (states.contains(WidgetState.selected)) {
                                  return _transactionType == 'SELL'
                                      ? Colors.green.shade700
                                      : Colors.indigo.shade700;
                                }
                                return null;
                              },
                            ),
                            foregroundColor: WidgetStateProperty.resolveWith<Color?>(
                              (states) {
                                if (states.contains(WidgetState.selected)) {
                                  return Colors.white;
                                }
                                return null;
                              },
                            ),
                          ),
                        ),

                        const SizedBox(height: 20),

                        // Product Selection Dropdown
                        DropdownButtonFormField<Product>(
                          value: _selectedProduct,
                          decoration: const InputDecoration(
                            labelText: 'Select Product',
                            border: OutlineInputBorder(),
                            prefixIcon: Icon(Icons.inventory_2),
                          ),
                          items: _products.map((Product p) {
                            return DropdownMenuItem<Product>(
                              value: p,
                              child: Text(
                                '${p.name} (Stock: ${p.quantity})',
                                overflow: TextOverflow.ellipsis,
                              ),
                            );
                          }).toList(),
                          onChanged: (Product? newValue) {
                            setState(() {
                              _selectedProduct = newValue;
                              _updatePriceFromSelectedProduct();
                            });
                          },
                          validator: (val) =>
                              val == null ? 'Please select a product' : null,
                        ),

                        if (_selectedProduct != null) ...[
                          const SizedBox(height: 8),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 4),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  'Current Stock: ${_selectedProduct!.quantity} units',
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                    color: _selectedProduct!.quantity == 0
                                        ? Colors.red
                                        : Colors.teal.shade800,
                                  ),
                                ),
                                Text(
                                  'Cost: $${_selectedProduct!.costPrice.toStringAsFixed(2)} | Retail: $${_selectedProduct!.sellingPrice.toStringAsFixed(2)}',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Colors.grey.shade600,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],

                        const SizedBox(height: 16),

                        // Quantity & Price Inputs
                        Row(
                          children: [
                            Expanded(
                              child: TextFormField(
                                controller: _quantityController,
                                keyboardType: TextInputType.number,
                                decoration: const InputDecoration(
                                  labelText: 'Quantity',
                                  border: OutlineInputBorder(),
                                  prefixIcon: Icon(Icons.numbers),
                                ),
                                onChanged: (_) => setState(() {}),
                                validator: (val) {
                                  if (val == null || val.trim().isEmpty) {
                                    return 'Required';
                                  }
                                  final num = int.tryParse(val.trim());
                                  if (num == null || num <= 0) {
                                    return 'Must be >= 1';
                                  }
                                  if (_transactionType == 'SELL' &&
                                      _selectedProduct != null &&
                                      num > _selectedProduct!.quantity) {
                                    return 'Max: ${_selectedProduct!.quantity}';
                                  }
                                  return null;
                                },
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: TextFormField(
                                controller: _priceController,
                                keyboardType: const TextInputType.numberWithOptions(
                                  decimal: true,
                                ),
                                decoration: InputDecoration(
                                  labelText: _transactionType == 'SELL'
                                      ? 'Unit Sale Price ($)'
                                      : 'Unit Buy Cost ($)',
                                  border: const OutlineInputBorder(),
                                  prefixIcon: const Icon(Icons.attach_money),
                                ),
                                onChanged: (_) => setState(() {}),
                                validator: (val) {
                                  if (val == null || val.trim().isEmpty) {
                                    return 'Required';
                                  }
                                  final num = double.tryParse(val.trim());
                                  if (num == null || num < 0) {
                                    return 'Must be >= 0';
                                  }
                                  return null;
                                },
                              ),
                            ),
                          ],
                        ),

                        const SizedBox(height: 20),

                        // Real-time calculation summary card
                        Card(
                          elevation: 0,
                          color: _transactionType == 'SELL'
                              ? (_projectedSaleProfit >= 0
                                  ? Colors.green.shade50
                                  : Colors.red.shade50)
                              : Colors.indigo.shade50,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                            side: BorderSide(
                              color: _transactionType == 'SELL'
                                  ? (_projectedSaleProfit >= 0
                                      ? Colors.green.shade200
                                      : Colors.red.shade200)
                                  : Colors.indigo.shade200,
                            ),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.all(16.0),
                            child: Column(
                              children: [
                                Row(
                                  mainAxisAlignment:
                                      MainAxisAlignment.spaceBetween,
                                  children: [
                                    Text(
                                      _transactionType == 'SELL'
                                          ? 'Total Sale Revenue:'
                                          : 'Total Purchase Cost:',
                                      style: TextStyle(
                                        fontSize: 14,
                                        fontWeight: FontWeight.w500,
                                        color: Colors.grey.shade800,
                                      ),
                                    ),
                                    Text(
                                      '$${_totalTransactionAmount.toStringAsFixed(2)}',
                                      style: const TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ],
                                ),
                                if (_transactionType == 'SELL') ...[
                                  const Divider(height: 18),
                                  Row(
                                    mainAxisAlignment:
                                        MainAxisAlignment.spaceBetween,
                                    children: [
                                      const Text(
                                        'Estimated Sale Profit:',
                                        style: TextStyle(
                                          fontSize: 15,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                      Text(
                                        '($${_currentEnteredPrice.toStringAsFixed(2)} - $${(_selectedProduct?.costPrice ?? 0.0).toStringAsFixed(2)}) × $_currentEnteredQuantity = $${_projectedSaleProfit.toStringAsFixed(2)}',
                                        style: TextStyle(
                                          fontSize: 14,
                                          fontWeight: FontWeight.bold,
                                          color: _projectedSaleProfit >= 0
                                              ? Colors.green.shade900
                                              : Colors.red.shade900,
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),

                        const SizedBox(height: 24),

                        FilledButton(
                          onPressed: _isSubmitting ? null : _submitTransaction,
                          style: FilledButton.styleFrom(
                            backgroundColor: _transactionType == 'SELL'
                                ? Colors.green.shade700
                                : Colors.indigo.shade700,
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          child: _isSubmitting
                              ? const SizedBox(
                                  height: 20,
                                  width: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                )
                              : Text(
                                  _transactionType == 'SELL'
                                      ? 'Complete Sale & Deduct Stock'
                                      : 'Complete Purchase & Add Stock',
                                  style: const TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                        ),
                      ],
                    ),
                  ),
                ),
    );
  }
}

// ==========================================
// 8. SCREEN 4: HISTORY (SALES & PURCHASES)
// ==========================================

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  final _currencyFormat = NumberFormat.currency(symbol: '$', decimalDigits: 2);
  final _dateFormat = DateFormat('yyyy-MM-dd HH:mm');
  List<TransactionRecord> _allTransactions = [];
  String _filter = 'ALL'; // 'ALL', 'SELL', 'BUY'
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadHistory();
  }

  Future<void> _loadHistory() async {
    setState(() => _isLoading = true);
    final txs = await DatabaseHelper.instance.getAllTransactions();
    setState(() {
      _allTransactions = txs;
      _isLoading = false;
    });
  }

  List<TransactionRecord> get _filteredTransactions {
    if (_filter == 'ALL') return _allTransactions;
    return _allTransactions.where((t) => t.type == _filter).toList();
  }

  @override
  Widget build(BuildContext context) {
    final list = _filteredTransactions;

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Transaction History',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadHistory,
          ),
        ],
      ),
      body: Column(
        children: [
          // Filter Chips
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
            child: Row(
              children: [
                ChoiceChip(
                  label: const Text('All'),
                  selected: _filter == 'ALL',
                  onSelected: (val) => setState(() => _filter = 'ALL'),
                ),
                const SizedBox(width: 8),
                ChoiceChip(
                  label: const Text('Sales (SELL)'),
                  selected: _filter == 'SELL',
                  onSelected: (val) => setState(() => _filter = 'SELL'),
                ),
                const SizedBox(width: 8),
                ChoiceChip(
                  label: const Text('Purchases (BUY)'),
                  selected: _filter == 'BUY',
                  onSelected: (val) => setState(() => _filter = 'BUY'),
                ),
              ],
            ),
          ),
          const Divider(height: 1),

          // List of past sales/purchases
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : list.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.history_toggle_off,
                                size: 56, color: Colors.grey.shade400),
                            const SizedBox(height: 12),
                            Text(
                              'No transactions recorded yet',
                              style: TextStyle(
                                fontSize: 16,
                                color: Colors.grey.shade700,
                              ),
                            ),
                          ],
                        ),
                      )
                    : ListView.separated(
                        padding: const EdgeInsets.all(16),
                        itemCount: list.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 10),
                        itemBuilder: (context, index) {
                          final tx = list[index];
                          final isSell = tx.type == 'SELL';
                          final profit = tx.profit;

                          DateTime parsedDate;
                          try {
                            parsedDate = DateTime.parse(tx.date);
                          } catch (_) {
                            parsedDate = DateTime.now();
                          }

                          return Card(
                            elevation: 0.5,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                              side: BorderSide(
                                color: isSell
                                    ? Colors.green.shade100
                                    : Colors.indigo.shade100,
                              ),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.all(14.0),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  // Type badge icon
                                  CircleAvatar(
                                    backgroundColor: isSell
                                        ? Colors.green.shade50
                                        : Colors.indigo.shade50,
                                    child: Icon(
                                      isSell
                                          ? Icons.call_made_rounded
                                          : Icons.call_received_rounded,
                                      color: isSell
                                          ? Colors.green.shade800
                                          : Colors.indigo.shade800,
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          mainAxisAlignment:
                                              MainAxisAlignment.spaceBetween,
                                          children: [
                                            Text(
                                              tx.productName ?? 'Unknown Product',
                                              style: const TextStyle(
                                                fontWeight: FontWeight.bold,
                                                fontSize: 16,
                                              ),
                                            ),
                                            Container(
                                              padding: const EdgeInsets.symmetric(
                                                horizontal: 8,
                                                vertical: 2,
                                              ),
                                              decoration: BoxDecoration(
                                                color: isSell
                                                    ? Colors.green.shade100
                                                    : Colors.indigo.shade100,
                                                borderRadius:
                                                    BorderRadius.circular(6),
                                              ),
                                              child: Text(
                                                tx.type,
                                                style: TextStyle(
                                                  fontWeight: FontWeight.bold,
                                                  fontSize: 12,
                                                  color: isSell
                                                      ? Colors.green.shade900
                                                      : Colors.indigo.shade900,
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                        const SizedBox(height: 4),
                                        Text(
                                          'Qty: ${tx.quantity}  @  ${_currencyFormat.format(tx.price)} each',
                                          style: TextStyle(
                                            fontSize: 13,
                                            color: Colors.grey.shade700,
                                          ),
                                        ),
                                        const SizedBox(height: 2),
                                        Text(
                                          _dateFormat.format(parsedDate),
                                          style: TextStyle(
                                            fontSize: 12,
                                            color: Colors.grey.shade500,
                                          ),
                                        ),
                                        const SizedBox(height: 6),
                                        // Individual profit/loss or total spent
                                        if (isSell)
                                          Container(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 8,
                                              vertical: 4,
                                            ),
                                            decoration: BoxDecoration(
                                              color: profit >= 0
                                                  ? Colors.green.shade50
                                                  : Colors.red.shade50,
                                              borderRadius:
                                                  BorderRadius.circular(6),
                                            ),
                                            child: Text(
                                              'Sale Profit: ${profit >= 0 ? "+" : ""}${_currencyFormat.format(profit)} (Cost: ${_currencyFormat.format(tx.productCostPrice ?? 0.0)})',
                                              style: TextStyle(
                                                fontWeight: FontWeight.bold,
                                                fontSize: 12,
                                                color: profit >= 0
                                                    ? Colors.green.shade900
                                                    : Colors.red.shade900,
                                              ),
                                            ),
                                          )
                                        else
                                          Text(
                                            'Total Purchase Cost: ${_currencyFormat.format(tx.price * tx.quantity)}',
                                            style: TextStyle(
                                              fontSize: 12,
                                              fontWeight: FontWeight.w500,
                                              color: Colors.indigo.shade800,
                                            ),
                                          ),
                                      ],
                                    ),
                                  ),
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
}
