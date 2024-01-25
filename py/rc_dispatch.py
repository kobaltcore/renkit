import inspect
import pydoc


def camel_to_snake(camel_case_str):
    snake_case_str = ""
    for char in camel_case_str:
        if char.isupper():
            snake_case_str += "_" + char.lower()
        else:
            snake_case_str += char
    # Remove leading underscore, if any
    snake_case_str = snake_case_str.lstrip("_")
    return snake_case_str


def dispatch(py_files: list[str]) -> list[dict[str, str]]:
    tasks = []

    for file in py_files:
        mod = pydoc.importfile(file)
        for info in inspect.getmembers(mod, inspect.isclass):
            name = info[0]
            class_ = info[1]
            if not name.endswith("Task"):
                continue
            name_slug = camel_to_snake(name[:-4])
            tasks.append({"name": name, "name_slug": name_slug, "class": class_})

    return tasks
