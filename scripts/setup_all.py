import json
from pathlib import Path

companies = [
    "Apple", "Alphabet", "Microsoft", "Amazon", "Oracle", "Epic Systems", 
    "UnitedHealth Group", "CVS Health", "Teladoc Health", "Veeva Systems", 
    "Dexcom", "Medtronic", "Abbott Laboratories", "Siemens Healthineers", 
    "Philips", "GE HealthCare", "athenahealth", "Salesforce", "IBM", 
    "Samsung", "Garmin", "Omada Health", "Noom", "Hims & Hers Health", "Tempus"
]

for name in companies:
    filename = f"examples/{name.lower().replace('&', 'and').replace(' ', '_')}.json"
    data = {
        "name": name, "location": "N/A", "url": "N/A", "type": "Public", 
        "size_class": "Large", "employee_count": 5000, "actions": "innovation", 
        "audiences": "global", "descriptor": "tech corp", "alignment_asset": "data infrastructure",
        "unc_strengths": "informatics", "contact_person": "N/A", "contact_rationale": "N/A",
        "ipo_status": "Yes", "unc_alum_details": "N/A", "donation_history": "N/A",
        "talking_points": [
            {"header": "Metric A", "body": "15 percent growth observed in 2026."},
            {"header": "Metric B", "body": "Revenue hit $1 billion in Q3."},
            {"header": "Metric C", "body": "Market share expanded by 5 percent."}
        ],
        "references": [
            {"author": "Corp Reports", "year": "2026", "title": "Annual Summary", "url": "n/a"},
            {"author": "Industry News", "year": "2026", "title": "Market Trends", "url": "n/a"}
        ]
    }
    with open(filename, 'w') as f: json.dump(data, f, indent=2)
