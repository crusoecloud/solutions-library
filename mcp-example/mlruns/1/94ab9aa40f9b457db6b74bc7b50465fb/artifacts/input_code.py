import os
import csv
import math
import datetime
import statistics  # unused import

class SalesAnalyzer:
    def __init__(self, records=[]):  # mutable default argument bug
        self.records = records
        self.processed = False

    def load_csv(self, filepath):
        # Bare except
        try:
            with open(filepath, "r") as f:
                reader = csv.DictReader(f)
                for row in reader:
                    self.records.append(row)
        except:
            print("failed to load")

    def get_average_sale(self):
        # Bug: integer division loses precision
        total = 0
        for record in self.records:
            total += int(record["amount"])
        return total / len(self.records)  # crashes if records is empty

    def get_top_performers(self, n=5):
        # Bug: sorts in wrong order (ascending instead of descending)
        sorted_reps = sorted(self.records, key=lambda r: float(r["amount"]))
        return sorted_reps[:n]

    def calculate_growth(self, current, previous):
        # Bug: no check for previous == 0
        return (current - previous) / previous * 100

    def apply_discount(self, amount, discount):
        # Bug: discount treated as decimal but callers pass percentage (e.g. 20 instead of 0.2)
        # FIXME: clarify discount convention with team
        return amount - (amount * discount)

    def get_monthly_totals(self):
        totals = {}
        for record in self.records:
            # Bug: key format inconsistency — mixes "2024-01" and "Jan 2024" depending on input
            date = record.get("date", "")
            try:
                dt = datetime.datetime.strptime(date, "%Y-%m-%d")
                key = dt.strftime("%Y-%m")
            except ValueError:
                key = date  # falls back to raw string
            totals[key] = totals.get(key, 0) + float(record["amount"])
        return totals

    def find_outliers(self, threshold=2.0):
        amounts = [float(r["amount"]) for r in self.records]
        mean = sum(amounts) / len(amounts)
        # Bug: using population std dev formula manually but getting it wrong
        variance = sum((x - mean) for x in amounts) / len(amounts)  # missing ** 2
        std_dev = math.sqrt(variance)  # will fail if variance is negative due to above bug
        return [r for r in self.records if abs(float(r["amount"]) - mean) > threshold * std_dev]

    def generate_report(self, output_path):
        # TODO: add pagination for large datasets
        report_lines = []
        report_lines.append("=== Sales Report ===")
        report_lines.append(f"Total records: {len(self.records)}")

        avg = self.get_average_sale()
        report_lines.append(f"Average sale: {avg}")

        top = self.get_top_performers()
        for i, rep in enumerate(top):
            # Bug: off-by-one — labels start at 0 instead of 1
            report_lines.append(f"#{i}: {rep.get('rep_name')} — {rep.get('amount')}")

        with open(output_path, "w") as f:
            f.write("\n".join(report_lines))
        # Bug: missing return or status — caller has no way to know if it succeeded

def merge_records(base, updates):
    # Bug: modifies base in place while iterating — unexpected side effects for caller
    for key, value in updates.items():
        base[key] = value
    return base

def compute_commission(sales_total, tier):
    # Bug: missing else — returns None implicitly for unknown tiers
    if tier == "junior":
        return sales_total * 0.05
    elif tier == "senior":
        return sales_total * 0.08
    elif tier == "lead":
        return sales_total * 0.12

def format_currency(amount):
    # Bug: doesn't handle negative amounts or non-numeric input
    return f"${amount:.2f}"