from slither import Slither
from slither.slithir.operations.internal_call import InternalCall
from slither.slithir.operations.high_level_call import HighLevelCall
from slither.slithir.operations.solidity_call import SolidityCall
from slither.slithir.operations.low_level_call import LowLevelCall
from slither.slithir.operations.event_call import EventCall
from slither.slithir.operations.library_call import LibraryCall
from slither.slithir.operations.internal_dynamic_call import InternalDynamicCall
import sys
import re
from colorama import Fore, Style, init as colorama_init

INDENT_SPACES_PER_DEPTH = 2

def remove_spaces_and_newlines(input):
    x = re.sub("//[^\n]*", "", input)
    x = re.sub("\n", " ", x)
    x = re.sub("[ ]+", " ", x)
    return x

def process_cli_args(args):
    if len(args) < 3:
        print(Style.BRIGHT + Fore.LIGHTRED_EX + f"Usage: {args[0]} target_file target_contract [target_function] [ignore_contracts_list]")
        exit(1)

    target_file = ""
    target_contract = ""
    target_function = ""
    ignore_contracts = []

    if len(args) >= 3:
        target_file = args[1]
        target_contract = args[2]
        if len(args) >= 4:
            target_function = args[3]
        if len(args) == 5:
            ignore_contracts = args[4].strip().split(",")

        
    return target_file, target_contract, target_function, ignore_contracts


def print_event_call(indent, target_contract):
    indent = " " * indent
    print(indent + Style.BRIGHT + Fore.LIGHTBLUE_EX + str(target_contract) + Style.RESET_ALL + " (Event emission)")

def print_library_call(indent, target_contract, target_function):
    indent = " " * indent
    print(indent + Style.BRIGHT + Fore.LIGHTMAGENTA_EX + str(target_contract) + "." + str(target_function) + Style.RESET_ALL + " (Library call)")

def print_lowlevel_call(indent, target_contract, target_function):
    indent = " " * indent
    print(indent + Style.BRIGHT + Fore.LIGHTMAGENTA_EX  + str(target_contract) + "." + str(target_function) + Style.RESET_ALL + " (Low level call)")

def print_internal_dynamic_call(indent, target_function):
    indent = " " * indent
    print(indent + Style.BRIGHT + Fore.LIGHTGREEN_EX + str(target_function) + Style.RESET_ALL + " (Internal dynamic call)")

def print_internal_call(indent, target_contract, target_function):
    indent = " " * indent
    if len(target_function.modifiers) > 0:
        all_mods = ",".join([m.name for m in target_function.modifiers])
        print(indent + Style.BRIGHT + Fore.LIGHTGREEN_EX + str(target_contract) + "." + str(target_function) + Style.RESET_ALL + f" (Internal privileged call, modifiers: {all_mods})")
    else:
        print(indent + Style.BRIGHT + Fore.LIGHTGREEN_EX + str(target_contract) + "." + str(target_function) + Style.RESET_ALL + " (Internal call)")

def print_external_call(indent, target_contract, target_function):
    indent = " " * indent
    if len(target_function.modifiers) > 0:
        all_mods = ",".join([m.name for m in target_function.modifiers])
        print(indent + Style.BRIGHT + Fore.LIGHTMAGENTA_EX + str(target_contract) + "." + str(target_function) + Style.RESET_ALL + f" (External privileged call, modifiers: {all_mods})")
    else:
        print(indent + Style.BRIGHT + Fore.LIGHTMAGENTA_EX + str(target_contract) + "." + str(target_function) + Style.RESET_ALL + " (External call)")

def print_solidity_call(indent, target_function):
    indent = " " * indent
    print(indent + Style.BRIGHT + Fore.LIGHTRED_EX + str(target_function) + Style.RESET_ALL + " (Solidity function)")

def print_modifiers(indent, modifiers):
    indent = " " * indent
    all_mods = ",".join([m.name for m in modifiers])
    print(indent + Style.BRIGHT + Fore.LIGHTGREEN_EX + "(Function modifiers: " + str(all_mods) + ")" + Style.RESET_ALL)

def print_heading(indent, function):
    indent = " " * indent
    if len(function.modifiers) > 0:
        all_mods = ",".join([m.name for m in function.modifiers])
        print(indent + Style.BRIGHT + Fore.LIGHTBLACK_EX + str(function.contract.name) + "." + str(function.name) + Style.RESET_ALL + f" (Privileged call, modifiers: {all_mods})")
    else:
        print(indent + Style.BRIGHT + Fore.LIGHTBLACK_EX + str(function.contract.name) + "." + str(function.name) + Style.RESET_ALL)


def follow_calls(depth_level, operations, ignore_contracts):
    for operation in operations: 
        if hasattr(operation, "contract_name") and operation.contract_name in ignore_contracts:
            continue
        if hasattr(operation, "destination") and operation.destination.name in ignore_contracts:
            continue


        if isinstance(operation, InternalCall):
            if operation.is_modifier_call:
                return
            print_internal_call(depth_level+INDENT_SPACES_PER_DEPTH, operation.contract_name, operation.function)
            follow_calls(depth_level+INDENT_SPACES_PER_DEPTH, operation.function.slithir_operations, ignore_contracts)

        elif isinstance(operation, HighLevelCall):
            print_external_call(depth_level+INDENT_SPACES_PER_DEPTH, operation.destination.name, operation.function)
            follow_calls(depth_level+INDENT_SPACES_PER_DEPTH, operation.function.slithir_operations, ignore_contracts)

        elif isinstance(operation, SolidityCall):
            # Special case for require calls, print the whole code for the call
            if "require" in operation.function.full_name:
                line = remove_spaces_and_newlines(str(operation.node.source_mapping.content))
                print_solidity_call(depth_level+INDENT_SPACES_PER_DEPTH, line)
            else:
                print_solidity_call(depth_level+INDENT_SPACES_PER_DEPTH, operation.function.full_name)

        elif isinstance(operation, LowLevelCall):
            print_lowlevel_call(depth_level+INDENT_SPACES_PER_DEPTH, operation.destination, operation.function_name)
        
        elif isinstance(operation, EventCall):
            print_event_call(depth_level+INDENT_SPACES_PER_DEPTH, operation.name)

        elif isinstance(operation, LibraryCall):
            print_library_call(depth_level+INDENT_SPACES_PER_DEPTH, operation.destination, operation.function_name)

        elif isinstance(operation, InternalDynamicCall):
            print_internal_dynamic_call(depth_level+INDENT_SPACES_PER_DEPTH, operation.function.name)
        
        else:
            # For future improvements.
            pass


# Initialization
colorama_init() 

# Parse command line args
target_file, target_contract, target_function, ignored = process_cli_args(sys.argv)

# Try to create a Slither object and get the contract from it
try:
    s = Slither(target_file)
except:
    print(Style.BRIGHT + Fore.LIGHTRED_EX + f"Error: Could not open the target file provided.")
    exit(1)

c = s.get_contract_from_name(target_contract)[0]
if c == []:
    print(Style.BRIGHT + Fore.LIGHTRED_EX + f"Error: Could not find the {target_contract} contract.")
    exit(1)

# Look for the functions. If none provided, by default consider all function entry points.
if target_function == "":
    entry_points = c.functions_entry_points
else:
    entry_points = [f for f in c.functions if f.name == target_function]

# For all target functions, analyze and print results
for f in entry_points:
    print_heading(0, f)
    follow_calls(0, f.slithir_operations, ignored)