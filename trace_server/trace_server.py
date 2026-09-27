"""TraceServer - in-program telnet trace server for Extron ControlScript projects.

Listens on a TCP port (conventionally 6000) and relays per-room debug trace to any connected
telnet client, including the PowerShell multilogger in this repo. See the README for wiring.
"""

from extronlib import event
from extronlib.system import Wait
from datetime import datetime


class TraceServer:

    # Rooms hold this object as room.trace; the per-room relay flag is
    # room.trace_enabled so the telnet debug toggle can't clobber the
    # server reference.
    def __init__(self, trace_server, processor, all_rooms):
        self.trace_server = trace_server
        self.processor = processor
        self.rooms = all_rooms

        self.start_trace_server()

        @event(trace_server, 'Connected')
        def trace_welcome_message(client, state) :
            client.Send("\n\rWelcome To {}'s Trace Server\n\rType 'Help' For Options\n\r".format(processor.DeviceAlias))

        @event(trace_server, 'ReceiveData')
        def trace_server_recv_data_server_event(interface, data):
            self.trace_server_recv_data(interface, data)

    def add_room(self, room):
            room.trace_enabled = False
            self.rooms.append(room)

    def trace_server_recv_data(self,interface, data):

        ## errors='ignore' - telnet clients send IAC negotiation bytes on connect which are not
        ## valid UTF-8 and would otherwise raise UnicodeDecodeError out of the event handler.
        data = data.decode('utf-8', errors='ignore').strip()

        if not data:
            return

        data = data.split(':')

        if len(data) < 2:
            data.append('')     ## single-word commands ('Help', 'ClearAll', 'Room Names') have no second part

        local_room = None

        for room in self.rooms:
            if room.name == data[0]:
                local_room = room
                break

        if local_room:
            if 'Status' == data[1]:
                self.trace_message('System', '{} Debug Is {}'.format(local_room.name, local_room.trace_enabled))

            elif 'Devices' == data[1]:
                self.trace_message('System', '\n{}:\n{}'.format(local_room.name, local_room))

            elif data[1] in ['True', 'False']:
                local_room.trace_enabled = 'T' in data[1]
                self.trace_message('System', '{} Debug Set {}'.format(local_room.name, local_room.trace_enabled))

        elif 'Room Names' == data[0]:
            self.trace_message('System', 'Room Names')
            for room in self.rooms:
                self.trace_message('System', 'Room Name: {}'.format(room.name))

        elif data[0] == 'All' and 'Status' in data[1]:
            for room in self.rooms:
                self.trace_message('System', '{}: {}'.format(room.name, room.trace_enabled))

        elif 'ClearAll' == data[0]:
            for room in self.rooms:
                room.trace_enabled = False
            self.trace_message('System', "Debug Cleared")

        elif 'Help' == data[0] :
            self.trace_message('System', "Commands\n"
                "'Room Names' (Provides List of Rooms\n"
                "'<roomname>:Status' or 'All:Status' (Provides Debug State)\n"
                "'<roomname>:Devices' (Provides Online State Of Room Devices)\n"
                "'<roomname>:<bool>' (Set Debug State)\n"
                "'ClearAll' (Set All Debug False)\n\r"
                )
        else:
            self.trace_message('System', "Invalid Command Try 'Help'")

    def trace_message(self, name, msg):
        # Mirror every trace message to the CSDU trace console
        print(name, '|', msg)
        try:
            for room in self.rooms:
                if room.name == name and room.trace_enabled or name == 'System':
                    for client in self.trace_server.Clients:
                        try:
                            client.Send('\n{}\n{} | {}\n\r'.format(datetime.now(), name, msg))
                        except:
                            pass
                    break
        except:
            print('TRACE: trace output skipped')
            pass

    def start_trace_server(self):
            # If the server is currently not listening
            if self.trace_server.StartListen() != 'Listening':
                # Start the server
                Wait(1, self.start_trace_server)
