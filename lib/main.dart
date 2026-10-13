import 'package:flutter/material.dart';

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

const String apiBaseUrl = String.fromEnvironment(
  'API_BASE_URL',
  defaultValue: 'http://127.0.0.1:8001',
);

void main() => runApp(const FinoraApp());

const green = Color(0xFF087F5B);
const navy = Color(0xFF12352F);
const canvas = Color(0xFFF4F7F6);

class Holding {
  String symbol, name;
  double quantity, buyPrice, currentPrice;
  String sector, industry;
  String? priceDate, priceSource;
  bool hasVerifiedPrice;

  Holding(
    this.symbol,
    this.name,
    this.quantity,
    this.buyPrice,
    this.currentPrice, {
    this.sector = 'other',
    this.industry = '',
    this.priceDate,
    this.priceSource,
    this.hasVerifiedPrice = false,
  });

  double get invested => quantity * buyPrice;
  double get value => quantity * currentPrice;
  double get profit => value - invested;
  double get returnPct => invested == 0 ? 0 : profit / invested * 100;
}

class _PriceUpdate {
  const _PriceUpdate({
    required this.holding,
    this.price,
    this.priceDate,
    this.priceSource,
    this.company,
    this.error,
  });

  final Holding holding;
  final double? price;
  final String? priceDate;
  final String? priceSource;
  final Map<String, dynamic>? company;
  final String? error;
}

class FinoraApp extends StatelessWidget {
  const FinoraApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Finora',
      theme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: canvas,
        colorScheme: ColorScheme.fromSeed(seedColor: green),
        cardTheme: CardThemeData(
          color: Colors.white,
          elevation: 0,
          surfaceTintColor: Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
            side: const BorderSide(color: Color(0xFFE6ECE9)),
          ),
        ),
        appBarTheme: const AppBarTheme(backgroundColor: canvas, elevation: 0),
      ),
      home: const PortfolioPage(),
    );
  }
}

class PortfolioPage extends StatefulWidget {
  const PortfolioPage({super.key});

  @override
  State<PortfolioPage> createState() => _PortfolioPageState();
}

class _PortfolioPageState extends State<PortfolioPage> {
  static const Duration _requestTimeout = Duration(seconds: 15);

  final List<Holding> holdings = [
    Holding('RELIANCE', 'Reliance Industries', 10, 1200, 1450, sector: 'other'),
    Holding(
      'TCS',
      'Tata Consultancy Services',
      8,
      3500,
      3300,
      sector: 'technology',
    ),
    Holding('INFY', 'Infosys', 20, 1400, 1550, sector: 'technology'),
    Holding('HDFCBANK', 'HDFC Bank', 15, 1600, 1700, sector: 'banking'),
  ];

  final ScrollController _marketWatchScrollController = ScrollController();
  Timer? _marketWatchTimer;
  bool refreshingPrices = false;
  bool loadingAnalytics = false;
  bool runningCrashTest = false;
  bool loadingMarketWatch = false;
  bool _marketWatchRefreshPending = false;
  String? marketPriceError;
  String? analyticsError;
  String? crashTestError;
  String? marketWatchError;
  Map<String, dynamic>? analyticsResult;
  Map<String, dynamic>? crashTestResult;
  List<Map<String, dynamic>> marketWatchItems = [];
  DateTime? marketWatchUpdatedAt;
  String? selectedAnalyticsSymbol;
  String crashScenario = 'market_crash';
  double marketShockPct = 20;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) refreshMarketWatch();
    });
    _marketWatchTimer = Timer.periodic(
      const Duration(seconds: 60),
      (_) => refreshMarketWatch(),
    );
  }

  @override
  void dispose() {
    _marketWatchTimer?.cancel();
    _marketWatchScrollController.dispose();
    super.dispose();
  }

  double get invested => holdings.fold(0, (sum, h) => sum + h.invested);

  double get value => holdings.fold(0, (sum, h) => sum + h.value);

  double get profit => value - invested;

  double get returnPct => invested == 0 ? 0 : profit / invested * 100;

  double get largestWeight => value == 0 || holdings.isEmpty
      ? 0
      : holdings.map((h) => h.value / value).reduce((a, b) => a > b ? a : b) *
            100;

  String money(double amount) {
    final fixed = amount.abs().toStringAsFixed(2).split('.');
    final integer = fixed.first;
    if (integer.length <= 3) {
      return '${amount < 0 ? '-' : ''}₹${fixed.join('.')}';
    }

    final groups = <String>[];
    var end = integer.length - 3;
    groups.add(integer.substring(end));
    while (end > 0) {
      final start = end > 2 ? end - 2 : 0;
      groups.add(integer.substring(start, end));
      end = start;
    }
    final formattedInteger = groups.reversed.join(',');
    return '${amount < 0 ? '-' : ''}₹$formattedInteger.${fixed.last}';
  }

  String _normalizeSector(String symbol, String? sector, String? industry) {
    final ticker = symbol.toUpperCase().split('.').first;
    const banks = {
      'HDFCBANK',
      'ICICIBANK',
      'SBIN',
      'AXISBANK',
      'KOTAKBANK',
      'BANKBARODA',
      'PNB',
      'INDUSINDBK',
      'FEDERALBNK',
      'IDFCFIRSTB',
      'YESBANK',
    };
    const technologyStocks = {
      'TCS',
      'INFY',
      'WIPRO',
      'HCLTECH',
      'TECHM',
      'LTIM',
      'MPHASIS',
      'PERSISTENT',
      'COFORGE',
    };
    if (banks.contains(ticker)) return 'banking';
    if (technologyStocks.contains(ticker)) return 'technology';
    final description = '${sector ?? ''} ${industry ?? ''}'.toLowerCase();
    if (description.contains('bank')) return 'banking';
    if (description.contains('technology') ||
        description.contains('software') ||
        description.contains('it services')) {
      return 'technology';
    }
    return 'other';
  }

  Future<void> addHolding() async {
    final result = await showDialog<Holding>(
      context: context,
      builder: (_) => const AddHoldingDialog(),
    );

    if (result != null && mounted) {
      setState(() {
        holdings.add(result);
        crashTestResult = null;
        crashTestError = null;
      });
      refreshMarketWatch();
    }
  }

  Map<String, dynamic> _decodeObject(http.Response response) {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      var message = 'Request failed (${response.statusCode}).';
      try {
        final body = jsonDecode(response.body);
        if (body is Map) {
          final detail = body['detail'] ?? body['message'] ?? body['error'];
          if (detail != null) message = detail.toString();
        }
      } on FormatException {
        // Keep the HTTP status message when the error response is not JSON.
      }
      throw Exception(message);
    }

    final decoded = jsonDecode(response.body);
    if (decoded is! Map) {
      throw const FormatException('The server returned an invalid response.');
    }
    return Map<String, dynamic>.from(decoded);
  }

  double? _numberValue(dynamic value) {
    final number = value is num
        ? value.toDouble()
        : value is String
        ? double.tryParse(value)
        : null;
    return number != null && number.isFinite ? number : null;
  }

  String _errorText(Object error) =>
      error.toString().replaceFirst(RegExp(r'^Exception: '), '');

  Future<List<_PriceUpdate>> _loadHoldingPrices(List<Holding> currentHoldings) {
    return Future.wait(
      currentHoldings.map((holding) async {
        try {
          final quoteResponse = await http
              .get(
                Uri.parse(
                  '$apiBaseUrl/api/quote/${Uri.encodeComponent(holding.symbol)}',
                ),
              )
              .timeout(_requestTimeout);
          final quote = _decodeObject(quoteResponse);
          final price = _numberValue(quote['latest_available_price']);
          if (price == null || price <= 0) {
            throw const FormatException(
              'The quote did not include a valid daily closing price.',
            );
          }

          Map<String, dynamic>? company;
          try {
            final companyResponse = await http
                .get(
                  Uri.parse(
                    '$apiBaseUrl/api/company/${Uri.encodeComponent(holding.symbol)}',
                  ),
                )
                .timeout(_requestTimeout);
            company = _decodeObject(companyResponse);
          } catch (_) {
            // A quote is still usable if optional company metadata is unavailable.
          }
          return _PriceUpdate(
            holding: holding,
            price: price,
            priceDate: quote['price_date']?.toString(),
            priceSource: quote['source']?.toString(),
            company: company,
          );
        } catch (error) {
          return _PriceUpdate(holding: holding, error: _errorText(error));
        }
      }),
    );
  }

  List<String> _applyPriceUpdates(List<_PriceUpdate> updates) {
    final errors = <String>[];
    for (final update in updates) {
      if (!holdings.contains(update.holding)) continue;
      if (update.price == null) {
        errors.add('${update.holding.symbol}: ${update.error}');
        continue;
      }
      update.holding
        ..currentPrice = update.price!
        ..priceDate = update.priceDate
        ..priceSource = update.priceSource
        ..hasVerifiedPrice = true;
      final company = update.company;
      if (company != null) {
        final resolvedSymbol = company['symbol']?.toString();
        final companyName = company['company_name']?.toString();
        if (resolvedSymbol != null && resolvedSymbol.isNotEmpty) {
          final oldSymbol = update.holding.symbol;
          update.holding.symbol = resolvedSymbol.toUpperCase();
          if (selectedAnalyticsSymbol == oldSymbol) {
            selectedAnalyticsSymbol = update.holding.symbol;
          }
        }
        if (companyName != null && companyName.isNotEmpty) {
          update.holding.name = companyName;
        }
        update.holding
          ..industry = company['industry']?.toString() ?? ''
          ..sector = _normalizeSector(
            update.holding.symbol,
            company['sector']?.toString(),
            company['industry']?.toString(),
          );
      }
    }
    return errors;
  }

  Future<void> refreshMarketPrices() async {
    if (holdings.isEmpty || refreshingPrices || runningCrashTest) return;
    setState(() {
      refreshingPrices = true;
      marketPriceError = null;
      crashTestResult = null;
      crashTestError = null;
    });

    final currentHoldings = List<Holding>.from(holdings);
    final updates = await _loadHoldingPrices(currentHoldings);
    if (!mounted) return;
    setState(() {
      final errors = _applyPriceUpdates(updates);
      refreshingPrices = false;
      crashTestResult = null;
      marketPriceError = errors.isEmpty ? null : errors.join('\n');
      analyticsResult = null;
    });
    refreshMarketWatch();
  }

  List<String> _watchSymbols() {
    return {
      ...holdings.map((holding) => holding.symbol.toUpperCase()),
      if (holdings.isEmpty) ...{'RELIANCE', 'TCS', 'INFY', 'HDFCBANK'},
    }.toList();
  }

  Future<void> refreshMarketWatch() async {
    if (!mounted) return;
    if (loadingMarketWatch) {
      _marketWatchRefreshPending = true;
      return;
    }
    setState(() {
      loadingMarketWatch = true;
      marketWatchError = null;
    });
    try {
      final uri = Uri.parse('$apiBaseUrl/api/market-watch')
          .replace(queryParameters: {'symbols': _watchSymbols().join(',')});
      final response = await http.get(uri).timeout(_requestTimeout);
      final result = _decodeObject(response);
      final rawItems = result['items'];
      if (rawItems is! List) {
        throw const FormatException(
          'The market-watch response did not include a quote list.',
        );
      }
      final items = rawItems
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .toList();
      if (!mounted) return;
      setState(() {
        marketWatchItems = items;
        marketWatchUpdatedAt = DateTime.now();
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => marketWatchError = _errorText(error));
    } finally {
      if (mounted) {
        setState(() => loadingMarketWatch = false);
        if (_marketWatchRefreshPending) {
          _marketWatchRefreshPending = false;
          refreshMarketWatch();
        }
      }
    }
  }

  Future<void> refreshAnalytics() async {
    final symbols = holdings.map((holding) => holding.symbol).toSet();
    final symbol = symbols.contains(selectedAnalyticsSymbol)
        ? selectedAnalyticsSymbol
        : symbols.isEmpty
        ? null
        : symbols.first;
    if (symbol == null || !symbols.contains(symbol) || loadingAnalytics) return;

    setState(() {
      loadingAnalytics = true;
      analyticsError = null;
    });
    try {
      final uri = Uri.parse(
        '$apiBaseUrl/api/analytics/${Uri.encodeComponent(symbol)}',
      ).replace(queryParameters: const {'period': '1y'});
      final response = await http.get(uri).timeout(_requestTimeout);
      final result = _decodeObject(response);
      if (!mounted) return;
      setState(() => analyticsResult = result);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        analyticsResult = null;
        analyticsError = _errorText(error);
      });
    } finally {
      if (mounted) setState(() => loadingAnalytics = false);
    }
  }

  Future<void> runCrashTest() async {
    if (holdings.isEmpty || runningCrashTest || refreshingPrices) return;
    setState(() {
      runningCrashTest = true;
      crashTestError = null;
      crashTestResult = null;
    });
    try {
      final holdingsBeforeRefresh = List<Holding>.from(holdings);
      final updates = await _loadHoldingPrices(holdingsBeforeRefresh);
      if (!mounted) return;
      final quoteErrors = updates
          .where((update) => update.price == null)
          .map((update) => '${update.holding.symbol}: ${update.error}')
          .toList();
      setState(() {
        _applyPriceUpdates(updates);
        analyticsResult = null;
        crashTestResult = null;
      });
      if (quoteErrors.isNotEmpty) {
        setState(() {
          crashTestError =
              'Refresh failed for ${quoteErrors.join('; ')}. '
              'No crash test was run. Retry after resolving these quotes.';
        });
        return;
      }

      final testedHoldings = List<Holding>.from(holdings);
      if (testedHoldings.any((holding) => !holding.hasVerifiedPrice)) {
        throw const FormatException(
          'Every holding must have a verified Yahoo Finance price.',
        );
      }
      final snapshotKey = _snapshotKey(testedHoldings);
      final startingValue = testedHoldings.fold<double>(
        0,
        (sum, holding) => sum + holding.value,
      );
      final payload = {
        'scenario': crashScenario,
        'market_shock_pct': marketShockPct.round(),
        'holdings': testedHoldings
            .map(
              (holding) => {
                'symbol': holding.symbol,
                'quantity': holding.quantity,
                'current_price': holding.currentPrice,
                'sector': holding.sector,
                'price_date': holding.priceDate,
                'price_source': holding.priceSource,
              },
            )
            .toList(),
      };
      final response = await http
          .post(
            Uri.parse('$apiBaseUrl/api/crash-test'),
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode(payload),
          )
          .timeout(_requestTimeout);
      final result = _decodeObject(response);
      final resultStartingValue = _numberValue(
        result['starting_portfolio_value'],
      );
      if (resultStartingValue == null ||
          (resultStartingValue - startingValue).abs() > 0.02) {
        throw const FormatException(
          'The crash-test response does not match the refreshed portfolio value.',
        );
      }
      if (!mounted) return;
      if (_snapshotKey(holdings) != snapshotKey) {
        throw const FormatException(
          'Holdings changed during the simulation. Run the test again.',
        );
      }
      setState(() => crashTestResult = result);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        crashTestResult = null;
        crashTestError = _errorText(error);
      });
    } finally {
      if (mounted) setState(() => runningCrashTest = false);
    }
  }

  String _snapshotKey(List<Holding> snapshot) => jsonEncode(
    snapshot
        .map(
          (holding) => [
            holding.symbol,
            holding.quantity,
            holding.buyPrice,
            holding.currentPrice,
            holding.sector,
            holding.priceDate,
          ],
        )
        .toList(),
  );

  String _formattedResult(
    Map<String, dynamic>? result,
    List<String> keys, {
    bool percentage = false,
    bool currency = false,
  }) {
    if (result == null) return '—';
    for (final key in keys) {
      final number = _numberValue(result[key]);
      if (number != null) {
        final formatted = currency
            ? _formatIndianAmount(number)
            : number.toStringAsFixed(2);
        return '$formatted${percentage ? '%' : ''}';
      }
    }
    return '—';
  }

  Widget _resultTile(String label, String value) {
    final isLoss = label == 'Estimated loss' || label == 'Loss percentage';
    return Container(
      width: 205,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isLoss ? const Color(0xFFFFF7F6) : const Color(0xFFF5F8F6),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isLoss ? const Color(0xFFF5E2DF) : const Color(0xFFE8EFEB),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label.toUpperCase(),
            style: const TextStyle(
              color: Colors.blueGrey,
              fontWeight: FontWeight.w700,
              fontSize: 9,
              letterSpacing: 0.8,
            ),
          ),
          const SizedBox(height: 8),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              value,
              maxLines: 1,
              style: TextStyle(
                color: isLoss ? Colors.redAccent : navy,
                fontWeight: FontWeight.w800,
                fontSize: 19,
                letterSpacing: -0.35,
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final positive = profit >= 0;
    final compactAppBar = MediaQuery.sizeOf(context).width < 560;

    return Scaffold(
      appBar: AppBar(
        title: const Row(
          children: [
            Icon(Icons.account_balance, color: green, size: 30),
            SizedBox(width: 10),
            Text(
              'finora',
              style: TextStyle(fontWeight: FontWeight.w800, fontSize: 26),
            ),
          ],
        ),
        actions: [
          if (!compactAppBar) ...[
            const Center(
              child: Text(
                'INVESTMENT INTELLIGENCE',
                style: TextStyle(
                  fontSize: 10,
                  letterSpacing: 1.4,
                  color: Colors.blueGrey,
                ),
              ),
            ),
            const SizedBox(width: 20),
          ],
          Padding(
            padding: EdgeInsets.only(right: compactAppBar ? 8 : 18),
            child: CircleAvatar(
              backgroundColor: navy,
              child: const Text('R', style: TextStyle(color: Colors.white)),
            ),
          ),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final contentWidth = constraints.maxWidth > 1320
              ? 1320.0
              : constraints.maxWidth;
          final horizontalPadding = constraints.maxWidth < 520 ? 14.0 : 24.0;
          return Center(
            child: SizedBox(
              width: contentWidth,
              child: ListView(
                padding: EdgeInsets.symmetric(
                  horizontal: horizontalPadding,
                  vertical: constraints.maxWidth < 520 ? 14 : 24,
                ),
                children: [
                  MarketWatchTicker(
                    items: marketWatchItems,
                    loading: loadingMarketWatch,
                    error: marketWatchError,
                    updatedAt: marketWatchUpdatedAt,
                    onRefresh: refreshMarketWatch,
                  ),
                  const SizedBox(height: 20),
                  const Text(
                    'Your portfolio',
                    style: TextStyle(fontSize: 29, fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'Understand your investments. Measure your risk.',
                    style: TextStyle(color: Colors.blueGrey),
                  ),
                  const SizedBox(height: 22),

                  LayoutBuilder(
                    builder: (context, constraints) {
                      final wide = constraints.maxWidth > 720;
                      final cards = [
                        metric(
                          'PORTFOLIO VALUE',
                          money(value),
                          Icons.account_balance_wallet_outlined,
                          'Current value of holdings',
                        ),
                        metric(
                          'TOTAL INVESTED',
                          money(invested),
                          Icons.savings_outlined,
                          'Original purchase value',
                        ),
                        metric(
                          'TOTAL PROFIT / LOSS',
                          '${positive ? '+' : '-'}${money(profit.abs())}',
                          Icons.trending_up,
                          '${returnPct.toStringAsFixed(2)}% total return',
                          highlight: positive,
                        ),
                      ];

                      return wide
                          ? Row(
                              children: cards
                                  .map(
                                    (card) => Expanded(
                                      child: Padding(
                                        padding: const EdgeInsets.only(
                                          right: 12,
                                        ),
                                        child: card,
                                      ),
                                    ),
                                  )
                                  .toList(),
                            )
                          : Column(
                              children: cards
                                  .map(
                                    (card) => Padding(
                                      padding: const EdgeInsets.only(
                                        bottom: 12,
                                      ),
                                      child: card,
                                    ),
                                  )
                                  .toList(),
                            );
                    },
                  ),

                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: OutlinedButton.icon(
                      onPressed:
                          refreshingPrices ||
                              holdings.isEmpty ||
                              runningCrashTest
                          ? null
                          : refreshMarketPrices,
                      icon: refreshingPrices
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.sync),
                      label: Text(
                        refreshingPrices
                            ? 'Refreshing prices...'
                            : 'Refresh Market Prices',
                      ),
                    ),
                  ),
                  const SizedBox(height: 5),
                  const Text(
                    'Prices are the latest available daily closes, not guaranteed real-time quotes.',
                    style: TextStyle(fontSize: 11, color: Colors.blueGrey),
                  ),
                  if (marketPriceError != null) ...[
                    const SizedBox(height: 8),
                    _errorBanner(marketPriceError!),
                  ],

                  const SizedBox(height: 14),
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final wide = constraints.maxWidth > 720;
                      final analysis = riskCard();
                      final allocation = allocationCard();

                      return wide
                          ? Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(child: analysis),
                                const SizedBox(width: 16),
                                Expanded(child: allocation),
                              ],
                            )
                          : Column(
                              children: [
                                analysis,
                                const SizedBox(height: 16),
                                allocation,
                              ],
                            );
                    },
                  ),

                  const SizedBox(height: 16),
                  analyticsCard(),
                  const SizedBox(height: 16),
                  crashTestCard(),

                  const SizedBox(height: 26),
                  Wrap(
                    alignment: WrapAlignment.spaceBetween,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 12,
                    runSpacing: 10,
                    children: [
                      const Text(
                        'Portfolio holdings',
                        style: TextStyle(
                          fontSize: 21,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      FilledButton.icon(
                        onPressed: runningCrashTest ? null : addHolding,
                        icon: const Icon(Icons.add),
                        label: const Text('Add holding'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '${holdings.length} ${holdings.length == 1 ? 'position' : 'positions'}'
                    ' • Current values based on latest available prices',
                    style: const TextStyle(
                      color: Colors.blueGrey,
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(height: 12),

                  if (holdings.isEmpty)
                    Card(
                      margin: EdgeInsets.zero,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 22,
                          vertical: 26,
                        ),
                        child: Column(
                          children: [
                            Container(
                              width: 48,
                              height: 48,
                              decoration: BoxDecoration(
                                color: const Color(0xFFEAF5F0),
                                borderRadius: BorderRadius.circular(15),
                              ),
                              child: const Icon(
                                Icons.account_balance_wallet_outlined,
                                color: green,
                              ),
                            ),
                            const SizedBox(height: 12),
                            const Text(
                              'Your portfolio is ready to build',
                              style: TextStyle(
                                color: navy,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 4),
                            const Text(
                              'Verify a stock to add your first position.',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: Colors.blueGrey,
                                fontSize: 12,
                              ),
                            ),
                            const SizedBox(height: 14),
                            OutlinedButton.icon(
                              onPressed: runningCrashTest ? null : addHolding,
                              icon: const Icon(Icons.add),
                              label: const Text('Add your first holding'),
                            ),
                          ],
                        ),
                      ),
                    ),

                  ...holdings.map(_holdingCard),

                  const SizedBox(height: 18),
                  const Text(
                    'DEMO MODE • Daily closing prices are not guaranteed real-time data or investment advice.',
                    style: TextStyle(fontSize: 11, color: Colors.blueGrey),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _holdingCard(Holding holding) {
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final compact = constraints.maxWidth < 540;
            final identity = Row(
              children: [
                CircleAvatar(
                  radius: 22,
                  backgroundColor: const Color(0xFFEAF5F0),
                  child: Text(
                    holding.symbol.substring(
                      0,
                      holding.symbol.length > 2 ? 2 : holding.symbol.length,
                    ),
                    style: const TextStyle(
                      color: green,
                      fontWeight: FontWeight.w800,
                      fontSize: 12,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        holding.symbol,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: navy,
                          fontWeight: FontWeight.w800,
                          fontSize: 14,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        holding.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.blueGrey,
                          fontSize: 11,
                        ),
                      ),
                      const SizedBox(height: 5),
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          _holdingTag('${holding.quantity} shares'),
                          _holdingTag(holding.sector),
                          _holdingTag(
                            holding.hasVerifiedPrice
                                ? 'Daily close${holding.priceDate == null ? '' : ' • ${holding.priceDate}'}'
                                : 'Demo price',
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            );
            final figures = Column(
              crossAxisAlignment: compact
                  ? CrossAxisAlignment.start
                  : CrossAxisAlignment.end,
              children: [
                Text(
                  money(holding.value),
                  style: const TextStyle(
                    color: navy,
                    fontWeight: FontWeight.w800,
                    fontSize: 16,
                    letterSpacing: -0.3,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  '${holding.profit >= 0 ? '+' : '-'}${money(holding.profit.abs())}'
                  '  (${holding.returnPct.toStringAsFixed(2)}%)',
                  style: TextStyle(
                    color: holding.profit >= 0 ? green : Colors.redAccent,
                    fontWeight: FontWeight.w600,
                    fontSize: 11,
                  ),
                ),
              ],
            );
            final removeButton = IconButton(
              tooltip: 'Remove ${holding.symbol}',
              onPressed: runningCrashTest
                  ? null
                  : () {
                      setState(() {
                        holdings.remove(holding);
                        crashTestResult = null;
                        crashTestError = null;
                        analyticsResult = null;
                      });
                      refreshMarketWatch();
                    },
              icon: const Icon(Icons.delete_outline),
            );

            if (compact) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(child: identity),
                      removeButton,
                    ],
                  ),
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: Divider(height: 1, color: Color(0xFFE9EFEC)),
                  ),
                  Row(
                    children: [
                      Expanded(child: figures),
                      Text(
                        'Invested ${money(holding.invested)}',
                        textAlign: TextAlign.end,
                        style: const TextStyle(
                          color: Colors.blueGrey,
                          fontSize: 10,
                        ),
                      ),
                    ],
                  ),
                ],
              );
            }

            return Row(
              children: [
                Expanded(flex: 5, child: identity),
                const SizedBox(width: 16),
                Expanded(child: figures),
                const SizedBox(width: 8),
                removeButton,
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _holdingTag(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: const Color(0xFFF3F6F4),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        text,
        style: const TextStyle(
          color: Colors.blueGrey,
          fontSize: 9,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _errorBanner(String message) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF1F0),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        message,
        style: const TextStyle(color: Colors.redAccent, fontSize: 12),
      ),
    );
  }

  Widget analyticsCard() {
    final symbols = holdings.map((holding) => holding.symbol).toSet().toList();
    final selectedSymbol = symbols.contains(selectedAnalyticsSymbol)
        ? selectedAnalyticsSymbol
        : symbols.isEmpty
        ? null
        : symbols.first;

    return Card(
      color: Colors.white,
      elevation: 0,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'QuantTech Analytics',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 6),
            const Text(
              'Historical risk and return metrics for a selected holding.',
              style: TextStyle(color: Colors.blueGrey, fontSize: 12),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 12,
              runSpacing: 10,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SizedBox(
                  width: 220,
                  child: DropdownButtonFormField<String>(
                    key: ValueKey<String?>(selectedSymbol),
                    initialValue: selectedSymbol,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Stock',
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                    ),
                    items: symbols
                        .map(
                          (symbol) => DropdownMenuItem(
                            value: symbol,
                            child: Text(symbol),
                          ),
                        )
                        .toList(),
                    onChanged: symbols.isEmpty || loadingAnalytics
                        ? null
                        : (symbol) {
                            setState(() {
                              selectedAnalyticsSymbol = symbol;
                              analyticsResult = null;
                              analyticsError = null;
                            });
                          },
                  ),
                ),
                FilledButton.icon(
                  onPressed: selectedSymbol == null || loadingAnalytics
                      ? null
                      : refreshAnalytics,
                  icon: loadingAnalytics
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.refresh),
                  label: Text(
                    loadingAnalytics ? 'Loading...' : 'Refresh analytics',
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            if (symbols.isEmpty)
              const Text('Add a holding to view its analytics.')
            else if (analyticsError != null)
              _errorBanner(analyticsError!)
            else if (analyticsResult != null) ...[
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  _resultTile(
                    'Latest available price',
                    _formattedResult(analyticsResult, [
                      'latest_available_price',
                    ], currency: true),
                  ),
                  _resultTile(
                    'Annualized volatility',
                    _formattedResult(analyticsResult, [
                      'annualized_volatility_pct',
                    ], percentage: true),
                  ),
                  _resultTile(
                    'Annualized return',
                    _formattedResult(analyticsResult, [
                      'annualized_return_pct',
                    ], percentage: true),
                  ),
                  _resultTile(
                    'Maximum drawdown',
                    _formattedResult(analyticsResult, [
                      'maximum_drawdown_pct',
                    ], percentage: true),
                  ),
                  _resultTile(
                    '1-day historical VaR (95%)',
                    _formattedResult(analyticsResult, [
                      'historical_var_95_one_day_pct',
                    ], percentage: true),
                  ),
                  _resultTile(
                    'Sharpe ratio (0% risk-free)',
                    _formattedResult(analyticsResult, [
                      'sharpe_ratio_zero_risk_free_rate',
                    ]),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              const Text(
                'Based on historical data; metrics are estimates, not forecasts.',
                style: TextStyle(fontSize: 11, color: Colors.blueGrey),
              ),
            ] else
              const Text('Select a stock and refresh to load analytics.'),
          ],
        ),
      ),
    );
  }

  Widget crashTestCard() {
    final scenarioExplanation = switch (crashScenario) {
      'banking_crisis' =>
        'Banking holdings receive ${marketShockPct.round()}%; other holdings receive ${(marketShockPct / 2).toStringAsFixed(1)}%.',
      'tech_selloff' =>
        'Technology holdings receive ${marketShockPct.round()}%; other holdings receive ${(marketShockPct / 2).toStringAsFixed(1)}%.',
      'custom' =>
        'The configured ${marketShockPct.round()}% shock applies uniformly.',
      _ => 'The configured ${marketShockPct.round()}% shock applies uniformly.',
    };
    final testedHoldings = crashTestResult?['holdings'];
    final contributors = testedHoldings is List
        ? testedHoldings
              .whereType<Map>()
              .map((holding) => Map<String, dynamic>.from(holding))
              .toList()
        : <Map<String, dynamic>>[];
    contributors.sort(
      (a, b) => (_numberValue(b['estimated_loss']) ?? 0).compareTo(
        _numberValue(a['estimated_loss']) ?? 0,
      ),
    );

    return Card(
      color: Colors.white,
      elevation: 0,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Portfolio Crash-Test Simulator',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 6),
            const Text(
              'Hypothetical stress scenarios are assumptions, not forecasts.',
              style: TextStyle(color: Colors.blueGrey, fontSize: 12),
            ),
            const SizedBox(height: 5),
            Text(
              scenarioExplanation,
              style: const TextStyle(color: Colors.blueGrey, fontSize: 12),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 12,
              runSpacing: 10,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SizedBox(
                  width: 220,
                  child: DropdownButtonFormField<String>(
                    initialValue: crashScenario,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Scenario',
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                    ),
                    items: const [
                      DropdownMenuItem(
                        value: 'market_crash',
                        child: Text('Market crash'),
                      ),
                      DropdownMenuItem(
                        value: 'banking_crisis',
                        child: Text('Banking crisis'),
                      ),
                      DropdownMenuItem(
                        value: 'tech_selloff',
                        child: Text('Tech selloff'),
                      ),
                      DropdownMenuItem(value: 'custom', child: Text('Custom')),
                    ],
                    onChanged: runningCrashTest
                        ? null
                        : (scenario) {
                            if (scenario != null) {
                              setState(() {
                                crashScenario = scenario;
                                crashTestResult = null;
                              });
                            }
                          },
                  ),
                ),
                SizedBox(
                  width: 280,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        crashScenario == 'banking_crisis'
                            ? 'Banking shock: ${marketShockPct.round()}%'
                            : crashScenario == 'tech_selloff'
                            ? 'Technology shock: ${marketShockPct.round()}%'
                            : 'Portfolio shock: ${marketShockPct.round()}%',
                      ),
                      Slider(
                        value: marketShockPct,
                        min: 0,
                        max: 100,
                        divisions: 100,
                        label: '${marketShockPct.round()}%',
                        onChanged: runningCrashTest
                            ? null
                            : (shock) => setState(() {
                                marketShockPct = shock;
                                crashTestResult = null;
                              }),
                      ),
                    ],
                  ),
                ),
                FilledButton.icon(
                  onPressed:
                      holdings.isEmpty || runningCrashTest || refreshingPrices
                      ? null
                      : runCrashTest,
                  icon: runningCrashTest
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.bolt),
                  label: Text(
                    runningCrashTest ? 'Simulating...' : 'Run crash test',
                  ),
                ),
              ],
            ),
            if (holdings.isEmpty) ...[
              const SizedBox(height: 8),
              const Text('Add a holding to run a portfolio crash test.'),
            ],
            if (crashTestError != null) ...[
              const SizedBox(height: 12),
              _errorBanner(crashTestError!),
            ],
            if (crashTestResult != null) ...[
              const SizedBox(height: 16),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  _resultTile(
                    'Starting portfolio value',
                    _formattedResult(crashTestResult, [
                      'starting_value',
                      'starting_portfolio_value',
                      'portfolio_value',
                    ], currency: true),
                  ),
                  _resultTile(
                    'Estimated loss',
                    _formattedResult(crashTestResult, [
                      'estimated_portfolio_loss',
                      'estimated_loss',
                      'loss',
                      'total_loss',
                    ], currency: true),
                  ),
                  _resultTile(
                    'Loss percentage',
                    _formattedResult(crashTestResult, [
                      'portfolio_loss_pct',
                      'loss_percentage',
                      'loss_pct',
                      'estimated_loss_pct',
                    ], percentage: true),
                  ),
                  _resultTile(
                    'Stressed portfolio value',
                    _formattedResult(crashTestResult, [
                      'stressed_portfolio_value',
                      'stressed_value',
                    ], currency: true),
                  ),
                ],
              ),
              if (contributors.isNotEmpty) ...[
                const SizedBox(height: 20),
                const Divider(height: 1, color: Color(0xFFE9EFEC)),
                const SizedBox(height: 18),
                const Text(
                  'Loss contribution by holding',
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
                ),
                const SizedBox(height: 4),
                const Text(
                  'Ranked by estimated contribution to total portfolio loss.',
                  style: TextStyle(color: Colors.blueGrey, fontSize: 11),
                ),
                const SizedBox(height: 8),
                ...contributors.asMap().entries.map(
                  (entry) => _lossContribution(
                    entry.key + 1,
                    entry.value,
                    contributors
                        .map(
                          (item) => _numberValue(item['estimated_loss']) ?? 0,
                        )
                        .fold<double>(
                          0,
                          (largest, loss) => loss > largest ? loss : largest,
                        ),
                  ),
                ),
                if (crashTestResult?['retrieved_at'] != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    'Calculated ${crashTestResult!['retrieved_at']} • '
                    '${crashTestResult?['price_source'] ?? 'Verified daily prices'}',
                    style: const TextStyle(
                      color: Colors.blueGrey,
                      fontSize: 10,
                    ),
                  ),
                ],
                if (crashTestResult?['disclaimer'] != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    crashTestResult!['disclaimer'].toString(),
                    style: const TextStyle(
                      color: Colors.blueGrey,
                      fontSize: 10,
                    ),
                  ),
                ],
              ],
            ],
          ],
        ),
      ),
    );
  }

  Widget _lossContribution(
    int rank,
    Map<String, dynamic> item,
    double maxLoss,
  ) {
    final loss = _numberValue(item['estimated_loss']) ?? 0;
    final shock = _numberValue(item['shock_pct']);
    final startingValue = _numberValue(item['starting_value']) ?? 0;
    final shareOfLoss = maxLoss <= 0 ? 0.0 : loss / maxLoss;
    final lossPct = startingValue <= 0 ? 0.0 : loss / startingValue * 100;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 9),
      child: Row(
        children: [
          SizedBox(
            width: 28,
            child: Text(
              rank.toString().padLeft(2, '0'),
              style: const TextStyle(
                color: Colors.blueGrey,
                fontFeatures: [FontFeature.tabularFigures()],
                fontWeight: FontWeight.w700,
                fontSize: 11,
              ),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        item['symbol']?.toString() ?? '—',
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: navy,
                          fontWeight: FontWeight.w700,
                          fontSize: 12,
                        ),
                      ),
                    ),
                    if (shock != null)
                      Text(
                        '${shock.toStringAsFixed(1)}% shock',
                        style: const TextStyle(
                          color: Colors.blueGrey,
                          fontSize: 10,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 6),
                ClipRRect(
                  borderRadius: BorderRadius.circular(5),
                  child: LinearProgressIndicator(
                    value: shareOfLoss.clamp(0, 1),
                    minHeight: 7,
                    backgroundColor: const Color(0xFFF5E7E4),
                    color: const Color(0xFFD85C51),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: 105,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  '-${_formatIndianAmount(loss)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.redAccent,
                    fontWeight: FontWeight.w700,
                    fontSize: 11,
                  ),
                ),
                Text(
                  '${lossPct.toStringAsFixed(2)}% holding value',
                  maxLines: 1,
                  style: const TextStyle(color: Colors.blueGrey, fontSize: 9),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget metric(
    String label,
    String amount,
    IconData icon,
    String subtitle, {
    bool highlight = true,
  }) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: const Color(0xFFEAF5F0),
                    borderRadius: BorderRadius.circular(11),
                  ),
                  child: Icon(icon, color: green, size: 20),
                ),
                const Spacer(),
                Container(
                  width: 7,
                  height: 7,
                  decoration: const BoxDecoration(
                    color: green,
                    shape: BoxShape.circle,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 19),
            Text(
              label,
              style: const TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.15,
                color: Colors.blueGrey,
              ),
            ),
            const SizedBox(height: 7),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                amount,
                style: TextStyle(
                  color: label == 'TOTAL PROFIT / LOSS'
                      ? (highlight ? green : Colors.redAccent)
                      : navy,
                  fontSize: 25,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.7,
                ),
              ),
            ),
            const SizedBox(height: 5),
            Text(
              subtitle,
              style: const TextStyle(color: Colors.blueGrey, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }

  Widget riskCard() {
    final risky = largestWeight >= 40;
    return Card(
      color: Colors.white,
      elevation: 0,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Portfolio risk insights',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Icon(
                  risky ? Icons.warning_amber_rounded : Icons.verified_outlined,
                  color: risky ? Colors.deepOrange : green,
                  size: 30,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    risky
                        ? 'High concentration detected'
                        : 'No high concentration detected',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              holdings.isEmpty
                  ? 'Add holdings to calculate portfolio concentration.'
                  : 'Largest holding: ${largestWeight.toStringAsFixed(1)}% of portfolio value.',
              style: const TextStyle(color: Colors.blueGrey),
            ),
            const SizedBox(height: 8),
            const Text(
              'Rule: a single holding at or above 40% is flagged for review.',
              style: TextStyle(fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }

  Widget allocationCard() {
    final colors = [
      green,
      const Color(0xFF5D8FE8),
      const Color(0xFFE4A64D),
      const Color(0xFF9B78D1),
      const Color(0xFFDB7777),
    ];

    return Card(
      color: Colors.white,
      elevation: 0,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Asset allocation',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 18),
            if (holdings.isEmpty || value <= 0)
              const Text('No allocation data available.')
            else
              ...holdings.asMap().entries.map((entry) {
                final h = entry.value;
                final weight = h.value / value;
                final color = colors[entry.key % colors.length];

                return Padding(
                  padding: const EdgeInsets.only(bottom: 14),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          Container(
                            width: 9,
                            height: 9,
                            decoration: BoxDecoration(
                              color: color,
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(child: Text(h.symbol)),
                          Text('${(weight * 100).toStringAsFixed(1)}%'),
                        ],
                      ),
                      const SizedBox(height: 7),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: LinearProgressIndicator(
                          value: weight,
                          minHeight: 7,
                          color: color,
                          backgroundColor: const Color(0xFFE8EEEB),
                        ),
                      ),
                    ],
                  ),
                );
              }),
          ],
        ),
      ),
    );
  }
}

String _formatIndianAmount(double amount) {
  final fixed = amount.abs().toStringAsFixed(2).split('.');
  final integer = fixed.first;
  if (integer.length <= 3) {
    return '${amount < 0 ? '-' : ''}₹${fixed.join('.')}';
  }
  final groups = <String>[];
  var end = integer.length - 3;
  groups.add(integer.substring(end));
  while (end > 0) {
    final start = end > 2 ? end - 2 : 0;
    groups.add(integer.substring(start, end));
    end = start;
  }
  return '${amount < 0 ? '-' : ''}₹${groups.reversed.join(',')}.${fixed.last}';
}

class MarketWatchTicker extends StatefulWidget {
  const MarketWatchTicker({
    required this.items,
    required this.loading,
    required this.error,
    required this.updatedAt,
    required this.onRefresh,
    super.key,
  });

  final List<Map<String, dynamic>> items;
  final bool loading;
  final String? error;
  final DateTime? updatedAt;
  final VoidCallback onRefresh;

  @override
  State<MarketWatchTicker> createState() => _MarketWatchTickerState();
}

class _MarketWatchTickerState extends State<MarketWatchTicker> {
  final ScrollController _controller = ScrollController();
  Timer? _scrollTimer;

  @override
  void initState() {
    super.initState();
    _scrollTimer = Timer.periodic(const Duration(milliseconds: 32), (_) {
      if (!_controller.hasClients || widget.items.isEmpty) return;
      final position = _controller.position;
      final loopWidth =
          (position.maxScrollExtent + position.viewportDimension) / 2;
      if (loopWidth <= 0) return;
      final next = position.pixels + 0.45;
      if (next >= loopWidth) {
        _controller.jumpTo(next - loopWidth);
      } else {
        _controller.jumpTo(next);
      }
    });
  }

  @override
  void dispose() {
    _scrollTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  double? _number(dynamic value) {
    final number = value is num
        ? value.toDouble()
        : value is String
        ? double.tryParse(value)
        : null;
    return number != null && number.isFinite ? number : null;
  }

  Widget _quoteCard(Map<String, dynamic> item) {
    final symbol = item['symbol']?.toString() ?? '—';
    final available = item['available'] != false;
    final price = _number(item['price'] ?? item['latest_available_price']);
    final changePct = _number(item['daily_change_pct']);
    final positive = (changePct ?? 0) >= 0;
    final status = item['source_status']?.toString();
    final isDailyClose =
        status == 'daily_close_fallback' || status == 'latest_daily_close';

    return Container(
      width: 218,
      height: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFFF4F7F6),
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: const Color(0xFFE7EEEB)),
      ),
      child: available && price != null
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        symbol,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: navy,
                          fontWeight: FontWeight.w800,
                          fontSize: 12,
                        ),
                      ),
                    ),
                    Text(
                      changePct == null
                          ? '—'
                          : '${positive ? '+' : ''}${changePct.toStringAsFixed(2)}%',
                      style: TextStyle(
                        color: positive ? green : Colors.redAccent,
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 3),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        _formatIndianAmount(price),
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 14,
                        ),
                      ),
                    ),
                    Icon(
                      positive
                          ? Icons.trending_up_rounded
                          : Icons.trending_down_rounded,
                      size: 17,
                      color: positive ? green : Colors.redAccent,
                    ),
                  ],
                ),
                Text(
                  '${item['company_name'] ?? symbol} • '
                  '${isDailyClose ? 'Daily close' : 'Delayed/current quote'}'
                  '${item['price_date'] == null ? '' : ' • ${item['price_date']}'}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.blueGrey, fontSize: 10),
                ),
              ],
            )
          : Center(
              child: Text(
                '$symbol unavailable',
                style: const TextStyle(color: Colors.blueGrey, fontSize: 12),
              ),
            ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final seenSymbols = <String>{};
    final availableItems = widget.items.where((item) {
      final symbol = item['symbol']?.toString().toUpperCase() ?? '';
      final normalized = symbol.split('.').first;
      return normalized.isNotEmpty && seenSymbols.add(normalized);
    }).toList();
    final updatedLabel = widget.updatedAt == null
        ? 'Not updated yet'
        : 'Updated ${TimeOfDay.fromDateTime(widget.updatedAt!).format(context)}';

    return Card(
      color: Colors.white,
      elevation: 0,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.show_chart, color: green, size: 19),
                const SizedBox(width: 7),
                const Expanded(
                  child: Text(
                    'Market Watch',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                  ),
                ),
                Text(
                  updatedLabel,
                  style: const TextStyle(color: Colors.blueGrey, fontSize: 10),
                ),
                const SizedBox(width: 4),
                IconButton(
                  tooltip: 'Refresh market watch',
                  visualDensity: VisualDensity.compact,
                  onPressed: widget.loading ? null : widget.onRefresh,
                  icon: widget.loading
                      ? const SizedBox(
                          width: 17,
                          height: 17,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh, size: 19),
                ),
              ],
            ),
            if (widget.error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  'Market data unavailable: ${widget.error}',
                  style: const TextStyle(color: Colors.redAccent, fontSize: 11),
                ),
              ),
            if (availableItems.isEmpty && widget.loading)
              const SizedBox(
                height: 52,
                child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
              )
            else if (availableItems.isEmpty)
              const SizedBox(
                height: 52,
                child: Center(
                  child: Text(
                    'No market quotes available. Use refresh to try again.',
                    style: TextStyle(color: Colors.blueGrey, fontSize: 12),
                  ),
                ),
              )
            else
              SizedBox(
                height: 80,
                child: ClipRect(
                  child: ListView.separated(
                    controller: _controller,
                    scrollDirection: Axis.horizontal,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: availableItems.length * 2,
                    separatorBuilder: (_, _) => const SizedBox(width: 9),
                    itemBuilder: (context, index) => _quoteCard(
                      availableItems[index % availableItems.length],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class AddHoldingDialog extends StatefulWidget {
  const AddHoldingDialog({super.key});

  @override
  State<AddHoldingDialog> createState() => _AddHoldingDialogState();
}

class _AddHoldingDialogState extends State<AddHoldingDialog> {
  final symbol = TextEditingController();
  final companyName = TextEditingController();
  final quantity = TextEditingController(text: '1');
  final buy = TextEditingController();
  bool verifying = false;
  String? verificationError;
  String? verifiedSymbol;
  String? verifiedSector;
  String? verifiedIndustry;
  String? verifiedPriceDate;
  double? verifiedPrice;

  bool get hasValidInputs {
    final qty = double.tryParse(quantity.text);
    final purchase = double.tryParse(buy.text);
    return verifiedSymbol != null &&
        verifiedPrice != null &&
        qty != null &&
        qty.isFinite &&
        qty > 0 &&
        purchase != null &&
        purchase.isFinite &&
        purchase > 0;
  }

  @override
  void dispose() {
    symbol.dispose();
    companyName.dispose();
    quantity.dispose();
    buy.dispose();
    super.dispose();
  }

  Future<void> verifyStock() async {
    final enteredSymbol = symbol.text.trim().toUpperCase();
    if (enteredSymbol.isEmpty || verifying) return;
    setState(() {
      verifying = true;
      verificationError = null;
      verifiedSymbol = null;
      verifiedPrice = null;
      companyName.clear();
    });
    try {
      final response = await http
          .get(
            Uri.parse(
              '$apiBaseUrl/api/company/${Uri.encodeComponent(enteredSymbol)}',
            ),
          )
          .timeout(const Duration(seconds: 15));
      final company = _decodeCompanyResponse(response);
      final ticker = company['symbol']?.toString();
      final name = company['company_name']?.toString();
      final priceValue = company['latest_available_price'];
      final price = priceValue is num
          ? priceValue.toDouble()
          : priceValue is String
          ? double.tryParse(priceValue)
          : null;
      if (ticker == null ||
          ticker.isEmpty ||
          name == null ||
          name.isEmpty ||
          price == null ||
          !price.isFinite ||
          price <= 0) {
        throw const FormatException(
          'Yahoo Finance did not return a verified company name and price.',
        );
      }
      if (!mounted) return;
      setState(() {
        verifiedSymbol = ticker.toUpperCase();
        companyName.text = name;
        verifiedPrice = price;
        verifiedSector = _normalizeVerifiedSector(
          ticker,
          company['sector']?.toString(),
          company['industry']?.toString(),
        );
        verifiedIndustry = company['industry']?.toString() ?? '';
        verifiedPriceDate = company['price_date']?.toString();
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        verifiedSymbol = null;
        verifiedPrice = null;
        verificationError = error.toString().replaceFirst(
          RegExp(r'^(Exception|FormatException): '),
          '',
        );
      });
    } finally {
      if (mounted) setState(() => verifying = false);
    }
  }

  Map<String, dynamic> _decodeCompanyResponse(http.Response response) {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      var message = 'Stock verification failed (${response.statusCode}).';
      try {
        final body = jsonDecode(response.body);
        if (body is Map && body['detail'] != null) {
          message = body['detail'].toString();
        }
      } on FormatException {
        // Keep the HTTP status message for non-JSON error responses.
      }
      throw Exception(message);
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! Map) {
      throw const FormatException('The verification response was invalid.');
    }
    return Map<String, dynamic>.from(decoded);
  }

  String _normalizeVerifiedSector(
    String ticker,
    String? sector,
    String? industry,
  ) {
    final symbol = ticker.toUpperCase().split('.').first;
    const bankTickers = {
      'HDFCBANK',
      'ICICIBANK',
      'SBIN',
      'AXISBANK',
      'KOTAKBANK',
      'BANKBARODA',
      'PNB',
    };
    const technologyTickers = {
      'TCS',
      'INFY',
      'WIPRO',
      'HCLTECH',
      'TECHM',
      'LTIM',
    };
    if (bankTickers.contains(symbol)) return 'banking';
    if (technologyTickers.contains(symbol)) return 'technology';
    final classification = '${sector ?? ''} ${industry ?? ''}'.toLowerCase();
    if (classification.contains('bank')) return 'banking';
    if (classification.contains('technology') ||
        classification.contains('software') ||
        classification.contains('it services')) {
      return 'technology';
    }
    return 'other';
  }

  void save() {
    final qty = double.tryParse(quantity.text);
    final purchase = double.tryParse(buy.text);

    if (!hasValidInputs ||
        qty == null ||
        purchase == null ||
        verifiedSymbol == null ||
        verifiedPrice == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Verify a stock and enter valid quantity and cost.'),
        ),
      );
      return;
    }

    Navigator.pop(
      context,
      Holding(
        verifiedSymbol!,
        companyName.text,
        qty,
        purchase,
        verifiedPrice!,
        sector: verifiedSector ?? 'other',
        industry: verifiedIndustry ?? '',
        priceDate: verifiedPriceDate,
        priceSource: 'Yahoo Finance verified daily close',
        hasVerifiedPrice: true,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 24),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: const BorderSide(color: Color(0xFFE6ECE9)),
      ),
      titlePadding: const EdgeInsets.fromLTRB(24, 22, 24, 8),
      contentPadding: const EdgeInsets.fromLTRB(24, 10, 24, 4),
      actionsPadding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
      title: const Row(
        children: [
          Icon(Icons.add_chart, color: green),
          SizedBox(width: 10),
          Expanded(
            child: Text(
              'Add investment',
              style: TextStyle(color: navy, fontWeight: FontWeight.w800),
            ),
          ),
        ],
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: EdgeInsets.only(bottom: 14),
                child: Text(
                  'Verify the listing before adding a position.',
                  style: TextStyle(color: Colors.blueGrey, fontSize: 12),
                ),
              ),
            ),
            TextField(
              controller: symbol,
              textCapitalization: TextCapitalization.characters,
              readOnly: verifying,
              decoration: const InputDecoration(
                labelText: 'Stock symbol (e.g. WIPRO)',
                border: OutlineInputBorder(),
              ),
              onChanged: (_) {
                setState(() {
                  verifiedSymbol = null;
                  verifiedPrice = null;
                  verifiedSector = null;
                  verifiedIndustry = null;
                  verifiedPriceDate = null;
                  companyName.clear();
                  verificationError = null;
                });
              },
            ),
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: verifying ? null : verifyStock,
                icon: verifying
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.verified_outlined),
                label: Text(verifying ? 'Verifying...' : 'Verify Stock'),
              ),
            ),
            if (verificationError != null)
              Container(
                width: double.infinity,
                margin: const EdgeInsets.only(bottom: 10),
                padding: const EdgeInsets.all(11),
                decoration: BoxDecoration(
                  color: const Color(0xFFFFF2F0),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: const Color(0xFFF5DBD7)),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(
                      Icons.error_outline,
                      size: 17,
                      color: Colors.redAccent,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        verificationError!,
                        style: const TextStyle(
                          color: Colors.redAccent,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            TextField(
              controller: companyName,
              readOnly: true,
              decoration: const InputDecoration(
                labelText: 'Verified company name',
                border: OutlineInputBorder(),
              ),
            ),
            if (verifiedSymbol != null) ...[
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFFF1F8F4),
                  borderRadius: BorderRadius.circular(11),
                  border: Border.all(color: const Color(0xFFDDECE3)),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.verified_rounded, color: green, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '$verifiedSymbol • ${verifiedSector ?? 'other'}'
                        '${verifiedPriceDate == null ? '' : '\nDaily close (${verifiedPriceDate!}): ${_formatIndianAmount(verifiedPrice!)}'}',
                        style: const TextStyle(
                          color: navy,
                          fontSize: 12,
                          height: 1.45,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 12),
            field(quantity, 'Quantity', numeric: true),
            field(buy, 'Purchase price per share (₹)', numeric: true),
            if (quantity.text.isNotEmpty &&
                (double.tryParse(quantity.text) == null ||
                    (double.tryParse(quantity.text) ?? 0) <= 0))
              _validationHint('Quantity must be greater than zero.'),
            if (buy.text.isNotEmpty &&
                (double.tryParse(buy.text) == null ||
                    (double.tryParse(buy.text) ?? 0) <= 0))
              _validationHint('Purchase price must be greater than zero.'),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: hasValidInputs ? save : null,
          child: const Text('Add holding'),
        ),
      ],
    );
  }

  Widget _validationHint(String message) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          message,
          style: const TextStyle(color: Colors.redAccent, fontSize: 11),
        ),
      ),
    );
  }

  Widget field(
    TextEditingController controller,
    String label, {
    bool numeric = false,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: TextField(
        controller: controller,
        onChanged: (_) {
          if (mounted) setState(() {});
        },
        keyboardType: numeric
            ? const TextInputType.numberWithOptions(decimal: true)
            : TextInputType.text,
        decoration: InputDecoration(
          labelText: label,
          filled: true,
          fillColor: const Color(0xFFFCFDFC),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(11),
            borderSide: const BorderSide(color: Color(0xFFDDE6E1)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(11),
            borderSide: const BorderSide(color: Color(0xFFDDE6E1)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(11),
            borderSide: const BorderSide(color: green, width: 1.5),
          ),
        ),
      ),
    );
  }
}
