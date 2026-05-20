import json
import subprocess
import sys
from pathlib import Path

TARGETS = {
    "Apple": "apple.com", "Alphabet": "abc.xyz", "Microsoft": "microsoft.com",
    "Amazon": "amazon.com", "Oracle": "oracle.com", "Epic Systems": "epic.com",
    "UnitedHealth Group": "unitedhealthgroup.com", "CVS Health": "cvshealth.com",
    "Teladoc Health": "teladochealth.com", "Veeva Systems": "veeva.com",
    "Dexcom": "dexcom.com", "Medtronic": "medtronic.com", "Abbott Laboratories": "abbott.com",
    "Siemens Healthineers": "siemens-healthineers.com", "Philips": "philips.com",
    "GE HealthCare": "gehealthcare.com", "athenahealth": "athenahealth.com",
    "Salesforce": "salesforce.com", "IBM": "ibm.com", "Samsung": "samsung.com",
    "Garmin": "garmin.com", "Omada Health": "omadahealth.com", "Noom": "noom.com",
    "Hims & Hers Health": "hims.com", "Tempus": "tempus.com"
}

def run_pipeline() -> None:
    md_dir, json_dir = Path("output/markdown"), Path("output/json")
    md_dir.mkdir(parents=True, exist_ok=True)
    json_dir.mkdir(parents=True, exist_ok=True)
    
    # Use sys.executable to ensure subprocess uses the same .venv python as this script
    python_exe = sys.executable 
    
    for name, domain in TARGETS.items():
        input_file = Path("examples") / f"{name.lower().replace(' ', '_')}.json"
        md_file = md_dir / f"{name.lower().replace(' ', '_')}_profile.md"
        json_file = json_dir / f"{name.lower().replace(' ', '_')}_profile.json"
        
        base_cmd = [python_exe, "-m", "src.main", "--name", name, "--url", domain, "--input", str(input_file)]
        
        try:
            subprocess.run(base_cmd + ["--output", str(md_file)], check=True, capture_output=True, text=True)
            subprocess.run(base_cmd + ["--output", str(json_file), "--format", "json"], check=True, capture_output=True, text=True)
            print(f"✓ Processed: {name}", file=sys.stderr)
        except subprocess.CalledProcessError as err:
            print(f"✗ Failed {name}: {err.stderr}", file=sys.stderr)

if __name__ == "__main__":
    run_pipeline()
