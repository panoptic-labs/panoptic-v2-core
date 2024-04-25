from slither import Slither
import sys
import re
from colorama import Fore, Style, init as colorama_init

def remove_spaces_and_newlines(input):
    x = re.sub("//[^\n]*", "", input)
    x = re.sub("\n", " ", x)
    x = re.sub("[ ]+", " ", x)
    return x

def process_cli_args(args):
    if len(args) != 4:
        print(Style.BRIGHT + Fore.LIGHTRED_EX + f"Usage: {args[0]} target_file target_contract var_name")
        exit(1)

    target_file = args[1]
    target_contract = args[2]
    var_name = args[3]

    return (target_file, target_contract, var_name)


def get_params(function_body):
    fb = remove_spaces_and_newlines(function_body)
    
    if "{" in fb:
        # get everything before the first curly brace
        header = fb.split("{")[0]

        # parameters should be between the first "(" and the first ")"
        params = header.split("(")[1].split(")")[0]

        return f"({params})"
    else:
        return ""


def get_returns(function_body):
    fb = remove_spaces_and_newlines(function_body)
    
    # get everything before the first curly brace
    header = fb.split("{")[0]

    # parameters should be between the first "(" and the first ")"
    if "returns" in header:
        returns = header.split("(")[2].split(")")[0]
        return f"returns({returns}) "
    else:
        return ""



colorama_init()
(file, contract, var) = process_cli_args(sys.argv)

# Try to create a Slither object and get the contract from it
try:
    s = Slither(file)
except:
    print(Style.BRIGHT + Fore.LIGHTRED_EX + f"Error: Could not open the target file provided.")
    exit(1)

c = s.get_contract_from_name(contract)
if c == []:
    print(Style.BRIGHT + Fore.LIGHTRED_EX + f"Error: Could not find the {contract} contract.")
    exit(1)
else:
    c = c[0]

for f in c.functions_entry_points:
    if f.is_constructor or f.is_receive or f.is_fallback or f.view:
        continue

    if f.visibility in ["public", "external"]:
        name = f"wrapper_{f.name}"
        params = f.parameters

        params_strings = "(" + ", ".join([f"{p.type} {p.name}" for p in params]) + ")"
        param_names = ", ".join([x.name for x in params])

        returns = get_returns(f.source_mapping.content)

        wrapper = f"function {name}{params_strings} public {returns}{{\n"
        wrapper += f"    hevm.prank(msg.sender);\n"
        wrapper += f"    {var}.{f.name}({param_names});\n"
        wrapper += f"}}\n\n"

        print(wrapper)
