from intersystems_pyprod import BusinessProcess, Status

iris_package_name = "Example"


class EchoBP(BusinessProcess):
    def OnRequest(self, request):
        return Status.OK(), request
