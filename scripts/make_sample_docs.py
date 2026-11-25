"""Generate sample municipal property records in four different formats.

Every town publishes assessment data differently, so the point of this script
is variety: different layouts, different labels for the same field, different
vocabulary ("NAT GAS" vs "Gas" vs "Natural Gas"), and a scanned-looking image
with a handwritten note. It also writes data/labels.csv with the true values so
extraction accuracy can be measured instead of guessed.

Two records (Springfield parcel 059700022 and Stamford parcel 4601) reuse the
property characteristics from public assessor records. Owner names on every
record are fake.

Usage:  .venv/bin/python scripts/make_sample_docs.py
"""
import csv
import random
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont
from reportlab.lib.pagesizes import letter
from reportlab.pdfgen import canvas

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "data" / "docs"
OUT.mkdir(parents=True, exist_ok=True)
random.seed(42)

FIELDS = [
    "municipality", "parcel_id", "address", "owner_name", "dwelling_style",
    "year_built", "year_remodeled", "stories", "living_area_sqft", "total_rooms",
    "bedrooms", "full_baths", "half_baths", "heating_fuel", "heating_system",
    "ac_type", "basement_type", "roof_structure", "last_sale_date",
    "last_sale_price", "assessed_value",
]

FIRST = ["Maria", "James", "Linda", "Robert", "Priya", "Daniel", "Grace", "Kevin",
         "Ana", "Thomas", "Mei", "Patrick", "Sofia", "Brian", "Nadia", "Carl"]
LAST = ["Alvarez", "Brennan", "Costa", "Doyle", "Ferreira", "Gallagher", "Hughes",
        "Kowalski", "Lindqvist", "Moreau", "Nguyen", "O'Rourke", "Pereira", "Quinlan"]

# Canonical vocab -> how each "town format" writes it
FUEL_WORDS = {
    "html":   {"Gas": "Gas", "Oil": "Oil", "Electric": "Electric", "Propane": "Propane", "Wood": "Wood"},
    "vision": {"Gas": "Gas", "Oil": "Oil", "Electric": "Electric", "Propane": "LP", "Wood": "Wood/Coal"},
    "town":   {"Gas": "Natural Gas", "Oil": "Fuel Oil #2", "Electric": "Electricity", "Propane": "Propane", "Wood": "Wood"},
    "scan":   {"Gas": "NAT GAS", "Oil": "OIL", "Electric": "ELEC", "Propane": "PROPANE", "Wood": "WOOD"},
}
# Keep fuel and distribution plausible together (no gas-fired electric baseboard)
SYSTEMS_BY_FUEL = {
    "Gas": ["Hot Water", "Forced Air-Ducted", "Steam"],
    "Oil": ["Hot Water", "Forced Air-Ducted", "Steam"],
    "Propane": ["Forced Air-Ducted", "Hot Water"],
    "Electric": ["Electric Baseboard", "Heat Pump"],
    "Wood": ["Space Heater", "Hot Water"],
}
STYLES = ["Cape", "Colonial", "Ranch", "Split Level", "Victorian", "Conventional", "Bungalow", "Raised Ranch"]
BASEMENTS = ["Full", "Partial", "Crawl Space", "Slab", "None"]
ROOFS = ["Gable/Hip", "Gambrel", "Flat", "Mansard", "Shed"]
AC = ["None", "Central", "Window/Wall", "Heat Pump"]

TOWNS = {
    "html": [("Springfield", "MA"), ("Chicopee", "MA"), ("Holyoke", "MA"), ("Westfield", "MA")],
    "vision": [("Stamford", "CT"), ("Norwalk", "CT"), ("New Britain", "CT"), ("Bristol", "CT")],
    "town": [("Worcester", "MA"), ("Fitchburg", "MA"), ("Leominster", "MA"), ("Gardner", "MA")],
    "scan": [("Pittsfield", "MA"), ("North Adams", "MA"), ("Greenfield", "MA"), ("Athol", "MA")],
}
STREETS = ["Maple St", "Oak Ave", "Elm St", "Pleasant St", "Chestnut St", "Highland Ave",
           "Union St", "Prospect St", "Summer St", "Walnut St", "Mill Rd", "Park Ave"]


def rand_record(fmt, town, state):
    year = random.choice([1890, 1905, 1922, 1938, 1951, 1958, 1964, 1972, 1979, 1986, 1995, 2004])
    remod = random.choice(["", "", str(min(2022, year + random.randint(30, 90)))]) if year < 1990 else ""
    beds = random.randint(2, 5)
    month, day = random.randint(1, 12), random.randint(1, 28)
    sale_year = random.choice([1998, 2006, 2012, 2017, 2021, 2023, 2024, 2025])
    sqft = random.randint(900, 3400)
    return {
        "municipality": f"{town}, {state}",
        "parcel_id": f"{random.randint(100, 999)}-{random.randint(10, 99)}-{random.randint(100, 999)}",
        "address": f"{random.randint(10, 480)} {random.choice(STREETS)}, {town} {state}",
        "owner_name": f"{random.choice(FIRST)} {random.choice(LAST)}",
        "dwelling_style": random.choice(STYLES),
        "year_built": str(year),
        "year_remodeled": remod,
        "stories": random.choice(["1", "1.5", "2", "2.5"]),
        "living_area_sqft": str(sqft),
        "total_rooms": str(beds + random.randint(2, 4)),
        "bedrooms": str(beds),
        "full_baths": str(random.randint(1, 3)),
        "half_baths": str(random.randint(0, 1)),
        "heating_fuel": (fuel := random.choice(["Gas", "Gas", "Oil", "Oil", "Electric", "Propane", "Wood"])),
        "heating_system": random.choice(SYSTEMS_BY_FUEL[fuel]),
        "ac_type": random.choice(AC),
        "basement_type": random.choice(BASEMENTS),
        "roof_structure": random.choice(ROOFS),
        "last_sale_date": f"{sale_year}-{month:02d}-{day:02d}",
        "last_sale_price": str(random.randint(90, 650) * 1000),
        "assessed_value": str(random.randint(160, 900) * 1000),
    }


def money(v):
    return f"${int(v):,}" if v else ""


def us_date(iso):
    y, m, d = iso.split("-")
    return f"{int(m)}/{int(d)}/{y}"


# ---------------------------------------------------------------- format 1: HTML
def write_html(rec, path):
    fuel = FUEL_WORDS["html"].get(rec["heating_fuel"], rec["heating_fuel"])
    rows = [
        ("Style", rec["dwelling_style"]), ("Year Built", rec["year_built"]),
        ("Stories", rec["stories"]), ("Living Area", f'{int(rec["living_area_sqft"]):,} SF'),
        ("Total Rooms", rec["total_rooms"]), ("Bedrooms", rec["bedrooms"]),
        ("Full Baths", rec["full_baths"]), ("Half Baths", rec["half_baths"]),
        ("Heat Fuel", fuel), ("Heat Type", rec["heating_system"]),
        ("AC Type", rec["ac_type"]), ("Basement", rec["basement_type"]),
        ("Roof Structure", rec["roof_structure"]),
    ]
    if rec["year_remodeled"]:
        rows.insert(2, ("Effective/Remodel Year", rec["year_remodeled"]))
    building = "\n".join(f"<tr><th>{k}</th><td>{v}</td></tr>" for k, v in rows)
    html = f"""<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>Parcel {rec['parcel_id']} - {rec['municipality']} Assessor</title>
<style>body{{font-family:Arial;font-size:13px}} th{{text-align:left;background:#eef;padding:3px 8px}} td{{padding:3px 8px}}</style></head>
<body>
<div id="nav"><a href="#">Home</a> | <a href="#">Search</a> | <a href="#">Tax Rates</a> | <a href="#">Abatements</a></div>
<h2>City of {rec['municipality'].split(',')[0]} - Board of Assessors</h2>
<p>Fiscal Year 2026 Property Record. Values are as of January 1, 2025.</p>
<h3>Parcel Information</h3>
<table>
<tr><th>Parcel ID</th><td>{rec['parcel_id']}</td></tr>
<tr><th>Location</th><td>{rec['address']}</td></tr>
<tr><th>Owner</th><td>{rec['owner_name'].upper()}</td></tr>
<tr><th>Total Assessed Value</th><td>{money(rec['assessed_value'])}</td></tr>
</table>
<h3>Sales History</h3>
<table><tr><th>Sale Date</th><th>Price</th><th>Book/Page</th></tr>
<tr><td>{us_date(rec['last_sale_date'])}</td><td>{money(rec['last_sale_price'])}</td><td>{random.randint(10000, 25000)}/{random.randint(1, 600)}</td></tr>
<tr><td>{us_date('1987-06-15')}</td><td>$84,000</td><td>6512/221</td></tr>
</table>
<h3>Building 1 - Residential</h3>
<table>
{building}
</table>
<p style="font-size:10px">Disclaimer: Information is believed reliable but not guaranteed.</p>
</body></html>"""
    path.write_text(html, encoding="utf-8")


# ---------------------------------------------------- format 2: Vision-style PDF card
def write_vision_pdf(rec, path):
    fuel = FUEL_WORDS["vision"].get(rec["heating_fuel"], rec["heating_fuel"])
    c = canvas.Canvas(str(path), pagesize=letter)
    w, h = letter

    def box(x, y, bw, bh, title, items, size=7):
        c.rect(x, y - bh, bw, bh)
        c.setFont("Helvetica-Bold", size + 1)
        c.drawString(x + 3, y - 10, title)
        c.setFont("Helvetica", size)
        yy = y - 21
        for k, v in items:
            c.drawString(x + 3, yy, f"{k}")
            c.drawRightString(x + bw - 4, yy, f"{v}")
            yy -= size + 3

    c.setFont("Helvetica-Bold", 10)
    c.drawString(30, h - 30, f"Property Location: {rec['address'].split(',')[0].upper()}")
    c.drawString(330, h - 30, f"Map ID: {rec['parcel_id']}   Bldg #: 1")
    c.setFont("Helvetica", 8)
    c.drawString(30, h - 42, f"Vision ID: {random.randint(1000, 9999)}   Account #: {random.randint(100000, 999999)}   "
                             f"{rec['municipality'].split(',')[0].upper()}, {rec['municipality'].split(', ')[1]}   Card # 1 of 1")
    box(30, h - 55, 270, 70, "CURRENT OWNER", [("", rec["owner_name"].upper()),
                                                ("", f"{random.randint(1, 99)} PO BOX"),
                                                ("", rec["municipality"].upper())])
    box(310, h - 55, 270, 70, "CURRENT ASSESSMENT", [("Description", "RES LAND/BLDG"),
                                                     ("Appraised", money(rec["assessed_value"])),
                                                     ("Assessed (70%)", money(int(int(rec["assessed_value"]) * 0.7)))])
    box(30, h - 135, 550, 60, "RECORD OF OWNERSHIP / SALE DATE / SALE PRICE", [
        (f"{rec['owner_name'].upper()}", f"{us_date(rec['last_sale_date'])}    {money(rec['last_sale_price'])}"),
        ("PRIOR OWNER TRUST", f"{us_date('2001-03-02')}    $0"),
        ("ESTATE OF PRIOR OWNER", f"{us_date('1979-11-20')}    $41,500")])
    box(30, h - 205, 550, 70, "PREVIOUS ASSESSMENTS (HISTORY)", [
        ("2025", money(int(int(rec["assessed_value"]) * 0.93))),
        ("2024", money(int(int(rec["assessed_value"]) * 0.88))),
        ("2023", money(int(int(rec["assessed_value"]) * 0.81)))])
    c.setFont("Helvetica-Oblique", 7)
    c.drawString(30, 60, "This information is believed to be correct but is subject to change and is not warranted.")
    c.showPage()

    # page 2: construction detail, where the energy-relevant fields live
    c.setFont("Helvetica-Bold", 10)
    c.drawString(30, h - 30, "CONSTRUCTION DETAIL")
    rows = [("Style", rec["dwelling_style"]), ("Model", "Residential"), ("Grade", "Average"),
            ("Stories", rec["stories"]), ("Occupancy", "1"),
            ("Exterior Wall 1", random.choice(["Vinyl Siding", "Clapboard", "Brick", "Wood Shingle"])),
            ("Roof Structure", rec["roof_structure"]), ("Roof Cover", "Asph/F Gls/Cmp"),
            ("Interior Wall 1", "Plastered"), ("Interior Flr 1", "Hardwood"),
            ("Heat Fuel", fuel), ("Heat Type", rec["heating_system"]), ("AC Type", rec["ac_type"]),
            ("Total Bedrooms", f'{rec["bedrooms"]} Bedrooms'), ("Total Bthrms", rec["full_baths"]),
            ("Total Half Baths", rec["half_baths"]), ("Total Rooms", f'{rec["total_rooms"]} Rooms'),
            ("Bsmt Type", rec["basement_type"])]
    box(30, h - 40, 270, 18 * 10 + 30, "Element / Cd / Description", rows)
    box(310, h - 40, 270, 80, "BUILDING SUMMARY", [
        ("Year Built", rec["year_built"]),
        ("Effective Year Built", rec["year_remodeled"] or rec["year_built"]),
        ("Remodel", f"Yes - {rec['year_remodeled']}" if rec["year_remodeled"] else "No"),
        ("Living Area", f'{int(rec["living_area_sqft"]):,}')])
    box(310, h - 130, 270, 70, "SUB-AREA SUMMARY", [
        ("BAS First Floor", f'{int(int(rec["living_area_sqft"]) * 0.55):,}'),
        ("FUS Upper Story", f'{int(int(rec["living_area_sqft"]) * 0.45):,}'),
        ("UBM Unfinished Bsmt", f'{int(int(rec["living_area_sqft"]) * 0.5):,}')])
    c.save()


# ---------------------------------------------- format 3: narrative town PDF
def write_town_pdf(rec, path):
    fuel = FUEL_WORDS["town"].get(rec["heating_fuel"], rec["heating_fuel"])
    c = canvas.Canvas(str(path), pagesize=letter)
    w, h = letter
    town = rec["municipality"].split(",")[0]
    c.setFont("Times-Bold", 14)
    c.drawString(60, h - 60, f"Town of {town} - Assessing Department")
    c.setFont("Times-Roman", 11)
    lines = [
        f"Field card summary for map/lot {rec['parcel_id']}, located at {rec['address']}.",
        f"Owner of record: {rec['owner_name']}. Deed recorded {us_date(rec['last_sale_date'])}, "
        f"consideration {money(rec['last_sale_price'])}.",
        "",
        f"The dwelling is a {rec['stories']}-story {rec['dwelling_style'].lower()} constructed in {rec['year_built']}"
        + (f" and substantially renovated in {rec['year_remodeled']}." if rec["year_remodeled"] else "."),
        f"Finished living area is {int(rec['living_area_sqft']):,} square feet over {rec['total_rooms']} rooms, "
        f"including {rec['bedrooms']} bedrooms, {rec['full_baths']} full bath(s) and {rec['half_baths']} half bath(s).",
        f"Heat Src: {fuel}.  Distribution: {rec['heating_system']}.  Cooling: {rec['ac_type']}.",
        f"Foundation/basement: {rec['basement_type']}.  Roof form: {rec['roof_structure']}.",
        "",
        f"FY2026 total valuation: {money(rec['assessed_value'])} (land and buildings).",
        "",
        "Inspection notes: interior inspection completed by data collector. Owner present.",
    ]
    if rec["heating_fuel"] == "":
        lines[5] = f"Heat Src: (not recorded).  Distribution: {rec['heating_system']}.  Cooling: {rec['ac_type']}."
    y = h - 95
    for ln in lines:
        c.drawString(60, y, ln)
        y -= 17
    c.save()


# ---------------------------------------------- format 4: scanned image
def write_scan(rec, path, note=None):
    fuel = FUEL_WORDS["scan"].get(rec["heating_fuel"], rec["heating_fuel"])
    img = Image.new("L", (1700, 2200), 245)
    d = ImageDraw.Draw(img)
    mono = ImageFont.truetype("/System/Library/Fonts/Supplemental/Courier New.ttf", 34)
    bold = ImageFont.truetype("/System/Library/Fonts/Supplemental/Courier New Bold.ttf", 40)
    hand = ImageFont.truetype("/System/Library/Fonts/Supplemental/Bradley Hand Bold.ttf", 44)
    town = rec["municipality"].split(",")[0].upper()
    d.text((120, 110), f"{town} BOARD OF ASSESSORS - PROPERTY CARD", font=bold, fill=20)
    y = 220
    rows = [("PARCEL", rec["parcel_id"]), ("LOCATION", rec["address"].split(",")[0].upper()),
            ("OWNER", rec["owner_name"].upper()), ("STYLE", rec["dwelling_style"].upper()),
            ("YR BLT", rec["year_built"]), ("YR REMOD", rec["year_remodeled"] or "-"),
            ("STORIES", rec["stories"]), ("GROSS LIV AREA", rec["living_area_sqft"]),
            ("RMS/BR/FB/HB", f'{rec["total_rooms"]}/{rec["bedrooms"]}/{rec["full_baths"]}/{rec["half_baths"]}'),
            ("HEAT FUEL", fuel), ("HEAT SYS", rec["heating_system"].upper()),
            ("A/C", rec["ac_type"].upper()), ("BSMT", rec["basement_type"].upper()),
            ("ROOF", rec["roof_structure"].upper()),
            ("LAST SALE", f'{us_date(rec["last_sale_date"])}  {money(rec["last_sale_price"])}'),
            ("TOTAL VALUE", money(rec["assessed_value"]))]
    for k, v in rows:
        d.text((120, y), f"{k:<16}", font=mono, fill=25)
        d.text((560, y), str(v), font=mono, fill=25)
        d.line((120, y + 48, 1580, y + 48), fill=150, width=1)
        y += 72
    if note:
        d.text((980, 920), note, font=hand, fill=60)
    # make it look like it went through an office scanner
    img = img.rotate(random.uniform(-1.8, 1.8), expand=False, fillcolor=235)
    noise = Image.effect_noise(img.size, 22)
    img = Image.blend(img, noise, 0.08).filter(ImageFilter.GaussianBlur(0.8))
    img.save(path, format="PNG")


# ------------------------------------------------------------------- build set
records = []

# Two records based on public assessor data (owner names replaced)
spring = {
    "municipality": "Springfield, MA", "parcel_id": "059700022",
    "address": "61 Grattan St, Springfield MA", "owner_name": "Daniel Moreau",
    "dwelling_style": "Cape", "year_built": "1951", "year_remodeled": "", "stories": "1.5",
    "living_area_sqft": "1554", "total_rooms": "7", "bedrooms": "4", "full_baths": "2",
    "half_baths": "0", "heating_fuel": "Gas", "heating_system": "Hot Water", "ac_type": "None",
    "basement_type": "Full", "roof_structure": "Gable/Hip", "last_sale_date": "2021-08-13",
    "last_sale_price": "265000", "assessed_value": "344700",
}
stamford = {
    "municipality": "Stamford, CT", "parcel_id": "4601",
    "address": "242 Ocean Drive West, Stamford CT", "owner_name": "Grace Lindqvist",
    "dwelling_style": "Colonial", "year_built": "1900", "year_remodeled": "2010", "stories": "2.5",
    "living_area_sqft": "4208", "total_rooms": "15", "bedrooms": "7", "full_baths": "5",
    "half_baths": "1", "heating_fuel": "Propane", "heating_system": "Forced Air-Ducted",
    "ac_type": "Central", "basement_type": "Full", "roof_structure": "Gable/Hip",
    "last_sale_date": "2017-05-30", "last_sale_price": "1650000", "assessed_value": "1758120",
}
records.append(("html", spring, "public_record_owner_replaced", None))
records.append(("vision", stamford, "public_record_owner_replaced", None))

notes = ["furnace repl. 2019 - oil", None, "new owner - see deed", None]
for fmt, towns in TOWNS.items():
    n = 3 if fmt in ("html", "vision") else 4
    for i in range(n):
        town, state = towns[i % len(towns)]
        rec = rand_record(fmt, town, state)
        note = notes[i] if fmt == "scan" else None
        records.append((fmt, rec, "synthetic", note))

# Deliberately awkward cases
records[-1][1]["heating_fuel"] = ""          # scan with no fuel recorded at all
records[-5][1]["heating_fuel"] = ""          # town narrative: "(not recorded)"

ext = {"html": "html", "vision": "pdf", "town": "pdf", "scan": "png"}
writer = {"html": write_html, "vision": write_vision_pdf, "town": write_town_pdf}

# Volume mode: `make_sample_docs.py --volume 500` writes N generated documents
# (equal mix of the four formats) to data/volume/, with their own labels file.
# Used to measure throughput and cost; the 16-document set is for accuracy.
if "--volume" in sys.argv:
    n_docs = int(sys.argv[sys.argv.index("--volume") + 1])
    random.seed(7)
    vol_out = ROOT / "data" / "volume"
    vol_out.mkdir(parents=True, exist_ok=True)
    fmts = list(TOWNS)
    with open(ROOT / "data" / "volume_labels.csv", "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["file_name", "source_format", "provenance", *FIELDS])
        for idx in range(1, n_docs + 1):
            fmt = fmts[(idx - 1) % len(fmts)]
            town, state = random.choice(TOWNS[fmt])
            rec = rand_record(fmt, town, state)
            town_slug = town.lower().replace(" ", "_")
            name = f"v{idx:04d}_{town_slug}_{fmt}.{ext[fmt]}"
            if fmt == "scan":
                write_scan(rec, vol_out / name, random.choice(notes))
            else:
                writer[fmt](rec, vol_out / name)
            w.writerow([name, fmt, "synthetic", *[rec[k] for k in FIELDS]])
    print(f"{n_docs} documents in {vol_out}")
    sys.exit(0)

with open(ROOT / "data" / "labels.csv", "w", newline="") as f:
    w = csv.writer(f)
    w.writerow(["file_name", "source_format", "provenance", *FIELDS])
    for idx, (fmt, rec, prov, note) in enumerate(records, start=1):
        town_slug = rec["municipality"].split(",")[0].lower().replace(" ", "_")
        name = f"{idx:02d}_{town_slug}_{fmt}.{ext[fmt]}"
        if fmt == "scan":
            write_scan(rec, OUT / name, note)
        else:
            writer[fmt](rec, OUT / name)
        w.writerow([name, fmt, prov, *[rec[k] for k in FIELDS]])
        print("wrote", name)

print(f"{len(records)} documents in {OUT}")
