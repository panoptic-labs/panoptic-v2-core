import re

def extract_svgs_correctly(file_path):
    svg_array = []
    with open(file_path, 'r', encoding='utf-8') as file:
        content = file.read()
        # Regular expression to match SVG content in comments
        svg_pattern = re.compile(r"//'(.*?)';", re.DOTALL)
        matches = svg_pattern.findall(content)
        for match in matches:
            # Escape double quotes with one slash
            escaped_svg = match.replace('"', '\\"')
            svg_array.append(f"\"{escaped_svg}\"")
    return svg_array

file_path = './periphery/SVGs/Art.sol'
svg_array = extract_svgs_correctly(file_path)
result = "[\n    " + ",\n    ".join(svg_array) + "\n]"
print(result)
