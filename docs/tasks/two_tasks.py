class ExampleTask:
    def __init__(self, config, input_dir, output_dir, renpy_path, registry):
        """
        Every tasks receives:
        - its own config object (parsed and but not validated dict of the input config file section)
        - the input directory of the build process
        - the output directory of the build process

        It is up to the task to validate the config object.
        """
        self.config = config
        self.input_dir = input_dir
        self.output_dir = output_dir
        self.renpy_path = renpy_path
        self.registry = registry

    def pre_build(self, on_builds):
        """
        This is the method that will be run in the pre-build stage of the build process.
        """
        print("task a pre")

    def post_build(self, on_builds):
        """
        This is the method that will be run in the post-build stage of the build process.
        """
        print("task a post")


class AnotherTask:
    """
    Multiple tasks may appear in the same file.
    """

    def __init__(self, config, input_dir, output_dir, renpy_path, registry):
        self.config = config
        self.input_dir = input_dir
        self.output_dir = output_dir
        self.renpy_path = renpy_path
        self.registry = registry

    def pre_build(self, on_builds):
        """
        You can supply only the methods you care about.
        In this case, we simply want to print something in the pre-build stage,
        so no config validation is needed and the post-build handler can be skipped.
        """
        print("task b pre")
