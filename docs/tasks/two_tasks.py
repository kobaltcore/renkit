class ExampleTask:
    def __init__(self, config, input_dir, output_dir):
        """
        Every tasks receives:
        - the full config object (parsed and validated dict of the input config file)
        - the input directory of the build process
        - the output directory of the build process
        """
        self.config = config
        self.input_dir = input_dir
        self.output_dir = output_dir

    @classmethod
    def validate_config(cls, config):
        """
        This method receives the subset of the config object related to this particular task.
        It should return the config it received, potentially with slight changes.
        Its main purpose is to validate its own config subset, so it should throw an Exception
        when it encounters an error.
        """
        return {**config, "new_option": 1}

    def pre_build(self):
        """
        This is the method that will be run in the pre-build stage of the build process.
        """
        print("task a pre")

    def post_build(self):
        """
        This is the method that will be run in the post-build stage of the build process.
        """
        print("task a post")


class AnotherTask:
    """
    Multiple tasks may appear in the same file.
    """

    def __init__(self, config, input_dir, output_dir):
        self.config = config
        self.input_dir = input_dir
        self.output_dir = output_dir

    def pre_build(self):
        """
        You can supply only the methods you care about.
        In this case, we simply want to print something in the pre-build stage,
        so no config validation is needed and the post-build handler can be skipped.
        """
        print("task b pre")
