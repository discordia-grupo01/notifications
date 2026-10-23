ExUnit.start()

Mox.defmock(Notifications.Unread.RepoMock, for: Notifications.Unread.Repo)
Mox.defmock(Notifications.Auth.TicketStoreMock, for: Notifications.Auth.TicketStore)
Mox.defmock(Notifications.PushMock, for: Notifications.Push)
