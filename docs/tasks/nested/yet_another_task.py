class YetAnotherTask:
    """
    Tasks can be nested and they will still be found by renconstruct.
    Note that the task name is the only thing that governs its name
    in the config section: The nested directories have no effect on its internal name.
    """

    def __init__(self, config, input_dir, output_dir, renpy_path, registry):
        self.config = config
        self.input_dir = input_dir
        self.output_dir = output_dir
        self.renpy_path = renpy_path
        self.registry = registry

    def post_build(self, on_builds):
        print("yet_another_task post build")
