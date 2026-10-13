from datetime import datetime, timezone
from threading import Lock
from time import monotonic

import numpy as np
import pandas as pd
import yfinance as yf
from fastapi import FastAPI, HTTPException, Query
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, Field

app = FastAPI(
    title="Finora QuantTech API",
    description=(
        "Stock market data, quantitative risk analytics, "
        "company verification, and portfolio stress tests."
    ),
    version="3.0.0",
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=[
        "http://localhost:5173",
        "http://127.0.0.1:5173",
        "http://localhost:3000",
        "http://127.0.0.1:3000",
        "http://localhost:8080",
        "http://127.0.0.1:8080",
    ],
    allow_origin_regex=r"https?://(localhost|127\.0\.0\.1)(:\d+)?",
    allow_credentials=False,
    allow_methods=["*"],
    allow_headers=["*"],
)

_CACHE_TTL_SECONDS = 60
_cache_lock = Lock()
_cache: dict[str, tuple[float, object]] = {}


def _cached(key: str):
    with _cache_lock:
        entry = _cache.get(key)
        if entry is not None and monotonic() - entry[0] < _CACHE_TTL_SECONDS:
            return entry[1]
    return None


def _store(key: str, value: object) -> None:
    with _cache_lock:
        _cache[key] = (monotonic(), value)


def _ticker_candidates(symbol: str) -> list[str]:
    normalized = symbol.strip().upper()
    if (
        not normalized
        or len(normalized) > 30
        or not all(character.isalnum() or character in ".-^=" for character in normalized)
    ):
        raise HTTPException(status_code=400, detail="Invalid stock symbol.")
    if "." in normalized or normalized.startswith("^"):
        return [normalized]
    return [f"{normalized}.NS", f"{normalized}.BO"]


def yahoo_symbol(symbol: str) -> str:
    return _ticker_candidates(symbol)[0]


def _fetch_history(symbol: str, period: str = "1y") -> tuple[str, pd.DataFrame]:
    candidates = _ticker_candidates(symbol)
    errors: list[str] = []
    for ticker_symbol in candidates:
        key = f"history:{ticker_symbol}:{period}"
        cached = _cached(key)
        if cached is not None:
            return ticker_symbol, cached
        try:
            history = yf.Ticker(ticker_symbol).history(
                period=period,
                interval="1d",
                auto_adjust=True,
            )
            if not history.empty and "Close" in history.columns:
                history = history.dropna(subset=["Close"])
                if not history.empty:
                    _store(key, history)
                    return ticker_symbol, history
            errors.append(f"No historical prices for {ticker_symbol}.")
        except Exception as error:
            errors.append(f"{ticker_symbol}: {str(error)[:120]}")

    if len(errors) == len(candidates) and all(
        message.startswith("No historical prices") for message in errors
    ):
        raise HTTPException(
            status_code=404,
            detail=f"No valid market history found for {symbol.strip().upper()}.",
        )
    raise HTTPException(
        status_code=502,
        detail=f"Yahoo Finance could not retrieve data for {symbol.strip().upper()}.",
    )


def get_history(symbol: str, period: str = "1y") -> pd.DataFrame:
    return _fetch_history(symbol, period)[1]


def _ticker_info(ticker_symbol: str) -> dict:
    try:
        info = yf.Ticker(ticker_symbol).get_info()
        return info if isinstance(info, dict) else {}
    except Exception:
        return {}


def _latest_daily_price(
    ticker_symbol: str, history: pd.DataFrame
) -> tuple[float, float | None, str]:
    latest = float(history["Close"].iloc[-1])
    previous = (
        float(history["Close"].iloc[-2]) if len(history.index) > 1 else None
    )
    return latest, previous, history.index[-1].strftime("%Y-%m-%d")


def _company_data(symbol: str) -> dict:
    cache_key = f"company:{symbol.strip().upper()}"
    cached = _cached(cache_key)
    if cached is not None:
        return cached

    failures: list[str] = []
    provider_failed = False
    for ticker_symbol in _ticker_candidates(symbol):
        try:
            history_key = f"history:{ticker_symbol}:5d"
            history = _cached(history_key)
            if history is None:
                history = yf.Ticker(ticker_symbol).history(
                    period="5d",
                    interval="1d",
                    auto_adjust=True,
                )
                if not history.empty and "Close" in history.columns:
                    history = history.dropna(subset=["Close"])
                    if not history.empty:
                        _store(history_key, history)
            if history is None or history.empty or "Close" not in history.columns:
                failures.append(f"No market history for {ticker_symbol}.")
                continue

            info = _ticker_info(ticker_symbol)
            name = next(
                (
                    info.get(key)
                    for key in ("longName", "shortName", "displayName")
                    if isinstance(info.get(key), str) and info[key].strip()
                ),
                None,
            )
            if not name:
                failures.append(f"Company name unavailable for {ticker_symbol}.")
                continue

            latest, previous, date = _latest_daily_price(ticker_symbol, history)
            result = {
                "symbol": ticker_symbol,
                "company_name": name.strip(),
                "sector": info.get("sector"),
                "industry": info.get("industry"),
                "latest_available_price": round(latest, 2),
                "previous_close": round(previous, 2) if previous is not None else None,
                "daily_change": (
                    round(latest - previous, 2) if previous is not None else None
                ),
                "daily_change_pct": (
                    round((latest / previous - 1) * 100, 2)
                    if previous not in (None, 0)
                    else None
                ),
                "price_date": date,
                "retrieved_at": datetime.now(timezone.utc).isoformat(),
                "currency": info.get("currency", "INR"),
                "source": "Yahoo Finance via yfinance",
                "source_status": "latest_daily_close",
            }
            _store(cache_key, result)
            return result
        except HTTPException:
            raise
        except Exception as error:
            provider_failed = True
            failures.append(str(error)[:120])

    if provider_failed and not any(
        message.startswith("Company name unavailable") for message in failures
    ):
        raise HTTPException(
            status_code=502,
            detail=f"Yahoo Finance could not verify {symbol.strip().upper()} right now.",
        )
    raise HTTPException(
        status_code=404,
        detail=(
            f"Could not verify {symbol.strip().upper()} on Yahoo Finance. "
            "Check the symbol or try an exchange suffix."
        ),
    )


def _normalize_sector(symbol: str, sector: str | None, industry: str | None) -> str:
    symbol = symbol.upper().split(".")[0]
    banks = {
        "HDFCBANK",
        "ICICIBANK",
        "SBIN",
        "AXISBANK",
        "KOTAKBANK",
        "BANKBARODA",
        "PNB",
        "INDUSINDBK",
        "FEDERALBNK",
        "IDFCFIRSTB",
        "YESBANK",
    }
    technology = {
        "TCS",
        "INFY",
        "WIPRO",
        "HCLTECH",
        "TECHM",
        "LTIM",
        "MPHASIS",
        "PERSISTENT",
        "COFORGE",
    }
    if symbol in banks:
        return "banking"
    if symbol in technology:
        return "technology"
    metadata = f"{sector or ''} {industry or ''}".lower()
    if "bank" in metadata:
        return "banking"
    if any(term in metadata for term in ("technology", "software", "it services")):
        return "technology"
    return "other"


@app.get("/")
def home():
    return {
        "app": "Finora QuantTech API",
        "status": "running",
        "version": app.version,
        "docs": "/docs",
    }


@app.get("/api/health")
def health():
    return {
        "status": "healthy",
        "timestamp": datetime.now(timezone.utc).isoformat(),
    }


@app.get("/api/company/{symbol}")
def verify_company(symbol: str):
    return _company_data(symbol)


@app.get("/api/market-watch")
def market_watch(
    symbols: str = Query(
        default="RELIANCE,TCS,INFY,HDFCBANK",
        max_length=600,
    )
):
    requested = list(dict.fromkeys(
        item.strip().upper() for item in symbols.split(",") if item.strip()
    ))
    if not requested:
        return {"items": [], "retrieved_at": datetime.now(timezone.utc).isoformat()}
    if len(requested) > 20:
        raise HTTPException(status_code=422, detail="A maximum of 20 symbols is allowed.")

    results = []
    for symbol in requested:
        try:
            try:
                company = _company_data(symbol)
            except HTTPException as error:
                if error.status_code != 404:
                    raise
                resolved_symbol, _ = _fetch_history(symbol, "5d")
                company = {
                    "symbol": resolved_symbol,
                    "company_name": symbol,
                    "currency": "INR",
                }
            ticker_symbol = company["symbol"]
            cached = _cached(f"watch:{ticker_symbol}")
            if cached is not None:
                results.append(cached)
                continue

            history = get_history(ticker_symbol, "5d")
            close, previous, price_date = _latest_daily_price(ticker_symbol, history)
            info = _ticker_info(ticker_symbol)
            price = close
            quote_time = price_date
            source_status = "daily_close_fallback"
            source = "Yahoo Finance latest available daily close"
            try:
                fast_info = yf.Ticker(ticker_symbol).fast_info
                live_price = fast_info.get("last_price")
                if live_price is not None and np.isfinite(float(live_price)):
                    price = float(live_price)
                    last_trade_time = fast_info.get("last_trade_time")
                    if last_trade_time:
                        quote_time = str(last_trade_time)
                    source_status = "delayed_or_current_quote"
                    source = "Yahoo Finance via yfinance fast_info"
            except Exception:
                pass

            item = {
                "symbol": ticker_symbol,
                "company_name": company["company_name"],
                "available": True,
                "price": round(price, 2),
                "latest_available_price": round(close, 2),
                "previous_close": round(previous, 2) if previous is not None else None,
                "daily_change": (
                    round(price - previous, 2) if previous is not None else None
                ),
                "daily_change_pct": (
                    round((price / previous - 1) * 100, 2)
                    if previous not in (None, 0)
                    else None
                ),
                "quote_timestamp": quote_time,
                "price_date": price_date,
                "currency": info.get("currency", company.get("currency", "INR")),
                "source": source,
                "source_status": source_status,
            }
            _store(f"watch:{ticker_symbol}", item)
            results.append(item)
        except HTTPException as error:
            results.append(
                {
                    "symbol": symbol,
                    "available": False,
                    "error": error.detail,
                    "source_status": "unavailable",
                }
            )

    return {"items": results, "retrieved_at": datetime.now(timezone.utc).isoformat()}


@app.get("/api/history/{symbol}")
def stock_history(
    symbol: str,
    period: str = Query(default="6mo", pattern="^(1mo|3mo|6mo|1y|2y|5y)$"),
):
    ticker_symbol, data = _fetch_history(symbol, period)
    history = [
        {
            "date": date.strftime("%Y-%m-%d"),
            "close": round(float(row["Close"]), 2),
            "volume": int(row["Volume"]) if pd.notna(row.get("Volume")) else 0,
        }
        for date, row in data.iterrows()
    ]
    closes = data["Close"]
    first_price = float(closes.iloc[0])
    latest_price = float(closes.iloc[-1])
    return {
        "symbol": ticker_symbol,
        "period": period,
        "currency": "INR",
        "latest_available_price": round(latest_price, 2),
        "price_date": data.index[-1].strftime("%Y-%m-%d"),
        "first_price": round(first_price, 2),
        "period_return_pct": round((latest_price / first_price - 1) * 100, 2),
        "data_points": len(history),
        "retrieved_at": datetime.now(timezone.utc).isoformat(),
        "source": "Yahoo Finance via yfinance",
        "data": history,
    }


@app.get("/api/quote/{symbol}")
def latest_available_quote(symbol: str):
    ticker_symbol, data = _fetch_history(symbol, "5d")
    latest, _, price_date = _latest_daily_price(ticker_symbol, data)
    return {
        "symbol": ticker_symbol,
        "latest_available_price": round(latest, 2),
        "price_date": price_date,
        "retrieved_at": datetime.now(timezone.utc).isoformat(),
        "source": "Yahoo Finance via yfinance",
        "source_status": "latest_daily_close",
        "note": "Latest available daily close, not guaranteed real-time.",
    }


@app.get("/api/analytics/{symbol}")
def stock_analytics(
    symbol: str,
    period: str = Query(default="1y", pattern="^(3mo|6mo|1y|2y|5y)$"),
):
    ticker_symbol, data = _fetch_history(symbol, period)
    prices = data["Close"]
    if len(prices) < 30:
        raise HTTPException(
            status_code=422,
            detail="At least 30 daily prices are required for analytics.",
        )
    returns = prices.pct_change().dropna()
    if returns.empty:
        raise HTTPException(status_code=422, detail="Insufficient valid returns.")
    volatility = float(returns.std() * np.sqrt(252) * 100)
    elapsed_days = (prices.index[-1] - prices.index[0]).total_seconds() / 86400
    years = elapsed_days / 365.25
    annual_return = (
        float(((prices.iloc[-1] / prices.iloc[0]) ** (1 / years) - 1) * 100)
        if years > 0
        else 0.0
    )
    drawdowns = prices / prices.cummax() - 1
    var_95 = max(0.0, float(-returns.quantile(0.05) * 100))
    daily_std = float(returns.std())
    sharpe = float(returns.mean() / daily_std * np.sqrt(252)) if daily_std > 0 else None
    return {
        "symbol": ticker_symbol,
        "period": period,
        "observations": len(returns),
        "latest_available_price": round(float(prices.iloc[-1]), 2),
        "price_date": prices.index[-1].strftime("%Y-%m-%d"),
        "annualized_volatility_pct": round(volatility, 2),
        "annualized_return_pct": round(annual_return, 2),
        "maximum_drawdown_pct": round(float(drawdowns.min() * 100), 2),
        "historical_var_95_one_day_pct": round(var_95, 2),
        "sharpe_ratio_zero_risk_free_rate": round(sharpe, 2) if sharpe is not None else None,
        "retrieved_at": datetime.now(timezone.utc).isoformat(),
        "source": "Yahoo Finance via yfinance",
    }


class HoldingInput(BaseModel):
    symbol: str = Field(min_length=1, max_length=30)
    quantity: float = Field(gt=0, le=1_000_000_000)
    current_price: float = Field(gt=0, le=1_000_000_000)
    sector: str = Field(default="other", max_length=50)
    price_date: str | None = None
    price_source: str | None = None
    custom_shock_pct: float | None = Field(default=None, ge=0, le=100)


class CrashTestRequest(BaseModel):
    holdings: list[HoldingInput] = Field(min_length=1, max_length=100)
    scenario: str = Field(default="market_crash", max_length=40)
    market_shock_pct: float = Field(default=20, ge=0, le=100)


@app.post("/api/crash-test")
def crash_test(request: CrashTestRequest):
    scenario = request.scenario.strip().lower()
    allowed = {"market_crash", "banking_crisis", "tech_selloff", "custom"}
    if scenario not in allowed:
        raise HTTPException(status_code=400, detail="Unsupported crash-test scenario.")

    total_value = sum(item.quantity * item.current_price for item in request.holdings)
    if total_value <= 0:
        raise HTTPException(status_code=422, detail="Total portfolio value must be positive.")

    tested_holdings = []
    total_loss = 0.0
    for item in request.holdings:
        market_value = item.quantity * item.current_price
        sector = item.sector.strip().lower()
        targeted_shock = request.market_shock_pct
        if scenario == "banking_crisis":
            shock = targeted_shock if sector == "banking" else targeted_shock * 0.5
        elif scenario == "tech_selloff":
            shock = targeted_shock if sector == "technology" else targeted_shock * 0.5
        elif scenario == "custom":
            shock = (
                item.custom_shock_pct
                if item.custom_shock_pct is not None
                else targeted_shock
            )
        else:
            shock = targeted_shock
        loss = market_value * shock / 100
        total_loss += loss
        tested_holdings.append(
            {
                "symbol": item.symbol.strip().upper(),
                "sector": sector,
                "quantity": item.quantity,
                "starting_price": round(item.current_price, 2),
                "starting_value": round(market_value, 2),
                "shock_pct": round(shock, 2),
                "estimated_loss": round(loss, 2),
                "stressed_value": round(market_value - loss, 2),
                "price_date": item.price_date,
                "price_source": item.price_source or "Verified Yahoo Finance quote",
            }
        )
    tested_holdings.sort(key=lambda item: item["estimated_loss"], reverse=True)
    return {
        "scenario": scenario,
        "currency": "INR",
        "starting_portfolio_value": round(total_value, 2),
        "estimated_portfolio_loss": round(total_loss, 2),
        "portfolio_loss_pct": round(total_loss / total_value * 100, 2),
        "stressed_portfolio_value": round(total_value - total_loss, 2),
        "holdings_tested": len(tested_holdings),
        "holdings": tested_holdings,
        "retrieved_at": datetime.now(timezone.utc).isoformat(),
        "price_source": "Verified Yahoo Finance quotes supplied by the client",
        "disclaimer": (
            "Hypothetical stress scenario, not a forecast. Banking/technology "
            "scenarios apply the configured shock to the target sector and half "
            "that shock to other holdings."
        ),
    }
