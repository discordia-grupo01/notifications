ExUnit.start()

Mox.defmock(Notifications.Unread.RepoMock, for: Notifications.Unread.Repo)
Mox.defmock(Notifications.Auth.TicketStoreMock, for: Notifications.Auth.TicketStore)
Mox.defmock(Notifications.PushMock, for: Notifications.Push)
Mox.defmock(Notifications.Delivery.RepoMock, for: Notifications.Delivery.Repo)
Mox.defmock(Notifications.Delivery.HttpMock, for: Notifications.Delivery.Http)
Mox.defmock(Notifications.Delivery.SenderMock, for: Notifications.Delivery.Sender)
