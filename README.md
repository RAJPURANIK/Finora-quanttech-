# Finora — QuantTech 📈
### Investment Intelligence & Portfolio Risk Analyzer

**Finora** is a fintech analytics dashboard that combines portfolio analysis, market data, quantitative risk metrics, and financial stress testing in one platform. Built with Flutter and FastAPI, it aims to make investment analysis more accessible through an intuitive, data-driven interface.

> **Analyze your portfolio. Understand your risk. Make more informed decisions.**

---

## ✨ Key Features

- **📊 Portfolio Dashboard** — View portfolio value, holdings, and investment summaries in one place.
- **🔎 Stock Verification** — Validate stock symbols and retrieve company information before adding holdings.
- **📈 Market Watch** — Track selected stocks, their latest available prices, and daily price movements.
- **⚖️ Portfolio Analytics** — Explore annualized returns, volatility, maximum drawdown, Sharpe ratio, and historical Value at Risk (VaR).
- **💥 Financial Stress Testing** — Simulate market crashes, banking crises, technology-sector sell-offs, and custom market shocks.
- **🧮 Risk Assessment** — Examine potential portfolio losses and stressed portfolio values under different scenarios.
- **🎨 Modern Dashboard UI** — A clean, responsive interface designed for financial data visualization and analysis.

## 🛠️ Tech Stack

| Layer | Technologies |
|---|---|
| Frontend | Flutter, Dart |
| Backend | Python, FastAPI |
| Market Data | yfinance |
| Data Analysis | Pandas, NumPy |
| API Communication | HTTP and REST APIs |
| Development Tools | VS Code, Git, GitHub |

## 🏗️ Architecture

```text
┌──────────────────────────────┐
│       Flutter Frontend       │
│                              │
│ Portfolio Dashboard          │
│ Market Watch                 │
│ Quantitative Analytics       │
│ Financial Stress Testing     │
└──────────────┬───────────────┘
               │
               │ HTTP / REST API
               ▼
┌──────────────────────────────┐
│       FastAPI Backend        │
│                              │
│ Stock Data & Validation      │
│ Portfolio Analytics          │
│ Risk Calculations            │
│ Market Stress Scenarios      │
└──────────────┬───────────────┘
               │
               ▼
┌──────────────────────────────┐
│       Market Data Source     │
│           yfinance           │
└──────────────────────────────┘
```

## 🚀 Getting Started

Follow these instructions to run Finora locally on Windows.

### Prerequisites

Install the following:

- [Flutter SDK](https://docs.flutter.dev/get-started/install)
- [Python 3](https://www.python.org/downloads/)
- [Git](https://git-scm.com/downloads)
- [Visual Studio Code](https://code.visualstudio.com/)

### 1. Clone the repository

```bash
git clone https://github.com/RAJPURANIK/Finora-quanttech-.git
cd Finora-quanttech-
```

### 2. Set up the backend

Open a terminal in the project directory:

```powershell
cd backend
python -m venv .venv
.\.venv\Scripts\Activate.ps1
```

Install the backend dependencies:

```powershell
python -m pip install fastapi "uvicorn[standard]" yfinance pandas numpy
```

Start the API server:

```powershell
python -m uvicorn main:app --reload --host 127.0.0.1 --port 8001
```

The backend will be available at:

- API: http://127.0.0.1:8001
- Interactive API documentation: http://127.0.0.1:8001/docs

Keep this terminal running.

### 3. Set up the Flutter frontend

Open a second terminal in the project root:

```powershell
flutter pub get
flutter run -d chrome
```

The Flutter application will launch in Chrome.

**Note:** The frontend expects the backend at `http://127.0.0.1:8001` for local development. Start the backend before testing features that require API access.

## 📉 Quantitative Risk Metrics

Finora includes quantitative measures designed to help users understand historical portfolio risk.

| Metric | Purpose |
|---|---|
| Annualized Return | Estimates return over a year using historical price data and the application's calculation method |
| Annualized Volatility | Measures the variability of historical returns |
| Maximum Drawdown | Measures the largest historical peak-to-trough decline |
| Value at Risk (VaR) | Estimates a historical one-day loss threshold at the 95% confidence level |
| Sharpe Ratio | Evaluates historical excess return relative to volatility, using a zero risk-free rate assumption |

These metrics describe historical data and model assumptions. They do not guarantee future performance.

## 💥 Financial Stress Testing

Finora's stress-testing functionality lets users examine hypothetical adverse market conditions.

Supported scenarios include:

- Market crash
- Banking crisis
- Technology-sector sell-off
- Custom stress scenario

The purpose is to estimate how a portfolio could respond to assumed market shocks. These simulations are hypothetical and should not be interpreted as forecasts.

## 📁 Project Structure

```text
Finora-quanttech-/
├── android/                 # Android platform files
├── backend/
│   └── main.py               # FastAPI application
├── ios/                      # iOS platform files
├── lib/
│   └── main.dart             # Flutter application
├── linux/                    # Linux platform files
├── macos/                    # macOS platform files
├── test/                     # Flutter tests
├── web/                      # Flutter web platform
├── windows/                  # Windows platform files
├── .gitignore
├── analysis_options.yaml
├── pubspec.lock
├── pubspec.yaml
└── README.md
```

## 🔐 Data & Limitations

- Market information is obtained through `yfinance`, which accesses Yahoo Finance data.
- Quotes may be delayed or represent the latest available daily closing price; real-time availability is not guaranteed.
- Historical analytics depend on the available data, selected period, and calculation assumptions.
- Stress-test results depend on hypothetical scenarios and are not predictions.
- Finora is an educational and analytical project, not a registered investment advisory service.
- Do not use its outputs as the sole basis for financial decisions.
- Never commit API keys, credentials, or other sensitive information to the repository.

## 🔮 Future Enhancements

Potential areas for further development include:

- Portfolio optimization and asset-allocation recommendations
- Advanced risk modelling and scenario comparisons
- Benchmark comparison against market indices
- Interactive historical performance charts
- Portfolio reporting and downloadable analytics
- Secure user authentication and persistent portfolio storage

## 🎯 Project Objective

Finora explores the intersection of **Financial Technology, Data Science, and Quantitative Finance** by combining market information, portfolio analytics, and scenario-based risk assessment in a single application.

The project demonstrates practical integration between a modern frontend, a Python API backend, financial data retrieval, and quantitative calculations.

## 👨‍💻 Author

**Raj Puranik**

Computer Science & Engineering — Data Science

GitHub: [@RAJPURANIK](https://github.com/RAJPURANIK)

---

## ⚠️ Disclaimer

Finora is developed for educational, demonstration, and research purposes. It does not provide personalized investment advice. Market data may be incomplete, delayed, or inaccurate. Always perform independent research before making investment decisions.
