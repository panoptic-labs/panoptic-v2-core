import os
import time;

def find_all_traces(where: str) -> list[str]:
    # "where" should contain the corpus dir, we manage from there
    if where[-1] != "/":
        where = f"{where}/"

    files = os.listdir(f"{where}/reproducers-traces/")

    out = []

    for file in files: 
        f = open(f"{where}/reproducers-traces/{file}", "r")
        out.append(f.read())
        f.close()
    
    return out

def replace_addresses(input: str, replacements: dict) -> str:
    # perform the actual replacement
    output = input
    for val in replacements.keys():
        output = output.replace(val, replacements[val])

    return output

def load_replacements(filename: str):
    # load the pairs from the file
    replacements = {}
    
    f = open(f"{filename}", "r")
    
    for line in f.readlines():
        line = line.strip()
        if line == "":
            continue

        v = line.split(",")
        replacements[v[0]] = v[1]

    f.close()

    return replacements

def write_replaced(where: str, what: str):
    out_dir = f"{where}/reproducers-traces-prettier/"
    if not os.path.exists(out_dir):
        os.makedirs(out_dir)

    filename = f"{what.splitlines()[0].split("(")[0]}-{int(time.time())}.txt"
    f = open(f"{out_dir}{filename}", "w")
    f.write(what)
    f.close()


CORPUS_DIR = "./contracts/fuzz/corpus/"
REPLACEMENTS_FILE = "./contracts/fuzz/address-replacements.txt"


traces = find_all_traces(CORPUS_DIR)
replacements = load_replacements(REPLACEMENTS_FILE)

for t in traces:
    replaced = replace_addresses(t, replacements)
    write_replaced(CORPUS_DIR, replaced)
    print(replaced)

